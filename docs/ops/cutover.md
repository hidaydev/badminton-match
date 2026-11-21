# Runbook: cutover v1 → v2

This document is a procedure the operator runs, not an architecture summary.
Cutover is **manual and one-way**: there is no side-by-side period, no cutover
from a push, and no automatic resume. The only way back is `rollback.sh`.

Status: executed. The sequence below ran on the VPS in the v2.0.0 release window
(2026-11-11 era) and production has served `bm2` since; `v2.0.2` is the current
release. The D-3 rehearsal gate was never met — `tools/rehearsal/timings.json`
still records `"status": "not_run"` — so the forward path is proven by the
cutover itself, and the rollback path is not proven by a rehearsal.

Before the window, run `cutover.sh --check --version v<version>`. It validates
the tools and resolves the signed release digest without taking the lock or
writing a step marker, and it exits 2 when `podman` is missing. The documented
host has no `psql`, `pg_dump` or `pg_restore`; `cutover.sh`, `backup.sh` and
`restore.sh` detect that and run those clients inside the PostgreSQL container
(`MAJADU_PG_CONTAINER`, default `qouver-postgres`) instead of installing
packages during the maintenance window. The container path is the supported one
on this host; the host-binary path remains for a host that already has them.

## 0. Principles that must not be violated

- The v1 image is tagged `:v1-final` **before** v1 is shut down. If tagging
  fails after v1 stops, there is no way back.
- v1 is `disable`d, not just `stop`ped. A reboot must not bring it back up and
  write to `bm`.
- `bm` is read-only: dump only, not a restore target, no DDL, no writes after
  cutover.
- `deploy-vps.sh` never runs a cutover and never reads `cutover.step`. If a push
  appears to "fix" the cutover, that is not a cutover.
- `:v1-final` is used only by `rollback.sh`. Post-cutover deploys use `:prev`.

## 1. Layout on the VPS

```
/srv/qouver/apps/majadu/
├── monorepo/                  # repo clone, source of the unit + db/migrations
├── scripts/                   # deploy-vps.sh, cutover.sh, rollback.sh, smoke.sh,
│                              # backup.sh, restore.sh (copied from the repo)
├── env/
│   ├── majadu-prod.env        # API unit env, symlink to .v1 or .v2 (mode 600)
│   ├── majadu-prod.env.v1     # MAJADU_PG_DSN → bm; no owner or ETL DSN
│   ├── majadu-prod.env.v2     # MAJADU_PG_DSN → bm2; no owner or ETL DSN
│   ├── majadu-tools.env       # job units + deploy/cutover DSNs (mode 600)
│   ├── ghcr-token             # mode 600; optional if podman is already logged in
│   └── alert.env              # mode 600; optional, MAJADU_ALERT_WEBHOOK
├── caddy/
│   ├── active.caddy           # symlink: site-v1 / site-v2 / site-maintenance
│   └── site-*.caddy           # copied by cutover.sh from ops/caddy/
├── cutover/                   # cutover.step, v1-final.digest, snapshot.*,
│                              # majadu-api.container.v1, env-target.v1
├── deploy/                    # deployed-version, last-release.json,
│                              # last-release.json.prev, last-attempt.json
├── backups/                   # mode 700; daily dump + bm-cutover-*.dump
└── logs/                      # deploy.log, cutover.log, caddy-access.log
```

`/etc/caddy/Caddyfile` imports `/srv/qouver/apps/majadu/caddy/active.caddy`
**inside** the `api.qouver.com` site, replacing the old `/majadu/*` handler. That
site also serves `/hooks`, `/sds`, and `/skyward`; the majadu snippet must not
replace the whole site. The `/majadu` prefix is kept after cutover, so the OIDC
redirect, `PUBLIC_BASE_URL`, and the web client do not change. The one-time steps
(including the share-log matcher) are in `ops/caddy/Caddyfile.api.qouver.com`.
The matcher is a site-level directive, so it lives in the companion
`ops/caddy/log-share.caddy` that cutover copies next to the three handler
snippets; the site block imports it. `cutover.sh --check` fails when the matcher
names one prefix, when it is defined but never skipped, and when the Majadu
handler is imported with no matcher at all.

## 2. The window, as executed

The D-7 checklist, the D-1 checks and the D-day steps of earlier revisions of
this document were carried out in the v2.0.0 window; the one command was

```sh
MAJADU_OWNER_SUB='<google-sub>' MAJADU_OWNER_EMAIL='<email>' \
  sudo -E /srv/qouver/apps/majadu/scripts/cutover.sh --version v2.0.0
```

`--version` must name a version whose release already exists, and the script
stops on its own when `cutover_state.completed_at` is already filled. The step
markers it wrote (`cutover/cutover.step`), the fixes the window forced and the
commit behind each one are in the git history (`git log -- ops/scripts/cutover.sh
ops/caddy/`); the running record is `deploy/last-release.json` and
`logs/cutover.log` on the host.

What the operator checked by hand afterwards. The Caddy site serves `/majadu/*`
with `uri strip_prefix`, so the prefix stays in the URL:

```sh
curl -fsS https://api.qouver.com/majadu/readyz
curl -fsS https://api.qouver.com/majadu/version
```

Two facts from that window that still matter on a rerun: `ops/systemd/` holds
ten timer units, and they may only be enabled once `MAJADU_PG_DSN` points at
`bm2` (the deploy installs unit files, it never enables timers);
`majadu-rotate-log.timer` fires every ten minutes (`OnCalendar=*:0/10`), not
hourly.

## 3. If it fails

The script stops with exit ≠ 0 and `cutover.step` points at the last step.
Pick one, not both:

**A. Continue from the failing step**: only if the cause is clear and already
fixed (for example a wrong role password):

```sh
/srv/qouver/apps/majadu/scripts/cutover.sh --version 2.0.2 --from <step>
```

`--from` does not re-check the earlier steps; the operator makes sure the state
on disk still matches (for example `:v1-final` exists and is correct).

**B. Go back to v1:**

```sh
sudo /srv/qouver/apps/majadu/scripts/rollback.sh --abandon-data
```

Rollback first counts how many bm2 rows were written after `completed_at`
(sessions, games, players, tournaments, rating events) and **refuses to run** if
there are writes without `--abandon-data`; the number that will be lost is
printed in the error message and in the log. The count runs through the host
`psql` or, on this host, through the PostgreSQL container; when neither client is
available the script refuses instead of skipping the guard, and
`--abandon-data` records that the count is unknown. Add `--drop-bm2` if the bm2
database should be dropped as well, rather than left behind for inspection.

Rollback restores `:v1-final`, the unit and env saved during `preserve-v1`, then
enables and restarts v1 and waits for `/healthz` before it touches Caddy. Only
after v1 answers does it point Caddy back to `site-v1.caddy` (`caddy validate`
plus a reload). A Caddy failure there is reported as a partial rollback: v1
keeps running, the site snippet is not switched, and the run pages. Once v1 is
healthy, rollback archives the `cutover_state` row to
`cutover/state-archive.json` and deletes it so the next cutover is not blocked.

If the rollback itself fails, do not rerun the cutover: recover by hand from
`cutover/majadu-api.container.v1`, `cutover/env-target.v1`, and the
`:v1-final` tag, then open an incident.

## 4. Consequences that must be announced on rollback

- **All v2 login sessions are void.** Users must log in again; v2 cookies point
  at the abandoned `account.sessions`.
- **v2 share links are dead.** Old v1 codes were not preserved during cutover
  either, so nothing comes back automatically. Links must be issued again
  after v1 is up.
- **The v2 FE bundle in browser caches must be force-reloaded.** `no-store` only
  applies to new documents; old tabs keep using the bundle already loaded.
- **`bm2` data written after cutover is discarded** (default: left behind;
  `--drop-bm2` drops the database). There is no migration back to `bm`.
- **`cutover_state` is deleted**, so the cutover can be run again; the old row
  is in `cutover/state-archive.json`.
- **`bm` does not change** during cutover or rollback: it is only read.

## 5. D+1

- [ ] `/readyz` green for 24 hours; no unexpected restarts
      (`systemctl --user status majadu-api`).
- [ ] `cutover_state.rows_imported` still matches the `bm_staging` count
      (checker cron or manual).
- [ ] No `majadu-alert@` in the journal.
- [ ] The daily `bm2` backup runs and can be read (`pg_restore --list`):
      enable `majadu-backup.timer` once `majadu-tools.env` carries
      `MAJADU_BACKUP_DSN_BM2` as `bm2_owner`; without it `backup.sh` refuses
      before dumping anything, and the unit reddens instead of skipping.
- [ ] The last `bm2` dump was restored into a scratch database, `bm2_app` read
      `select 1 from platform.community`, `select count(*) from
      dbtools.schema_migrations` matched the file count, and `dbtools verify`
      exited 0.
- [ ] The first session created by a real user shows up on the leaderboard.
- [ ] `rating.snapshots` gained yesterday's date
      (`select max(taken_on) from rating.snapshots`), and the arrows on the
      board use that snapshot.
- [ ] Record any deviation (numbers, UI, login) in the incident note if there is
      one.

## 6. D+30

- [ ] `bm` stays read-only; the `bm2_*` roles cannot `CONNECT` to it
      (`ops/db/roles.sql` already enforces this with assertions).
- [ ] The daily `bm` dump stops; keep one final dump outside the rotation.
- [ ] `:v1-final` is kept until T-082: archive it as a tarball
      (`podman save`) **before** the tag is removed, then delete it together
      with the Go decommission.
- [ ] Review whether `majadu-prod.env.v1` and the v1 `ops/scripts` are still
      needed; do not delete `:v1-final` earlier than 30 days.

## 7. What is not yet proven until the D-3 rehearsal

`tools/rehearsal/timings.json` still records `"status": "not_run"`, so the
rehearsal never replaced the targets in this document with measurements. What
that leaves unproven is the rollback-and-resume path as one rehearsed run:
`rollback.sh` followed by `cutover.sh --from restore-staging`, on the real
Quadlet and Caddy, inside an announced window. The forward path is proven by the
cutover that shipped v2.0.0; §3 is the procedure if it has to be walked again.