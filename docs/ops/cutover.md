# Runbook: cutover v1 → v2

This document is a procedure the operator runs, not an architecture summary.
Cutover is **manual and one-way**: there is no side-by-side period, no cutover
from a push, and no automatic resume. The only way back is `rollback.sh`.

Status: the sequence below follows the scripts present in the repo
(`ops/scripts/`), but it has **never been executed on the VPS**. The D-3
rehearsal is what proves the Quadlet, Caddy, and `:v1-final` steps; until that
rehearsal is done, treat every step here as untested.

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
│   ├── majadu-tools.env       # OWNER/ETL/SOURCE/RESTORE DSNs (mode 600)
│   ├── ghcr-token             # mode 600; optional if podman is already logged in
│   └── alert.env              # mode 600; optional, MAJADU_ALERT_WEBHOOK
├── caddy/
│   ├── active.caddy           # symlink: site-v1 / site-v2 / site-maintenance
│   └── site-*.caddy           # copied by cutover.sh from ops/caddy/
├── cutover/                   # cutover.step, v1-final.digest, snapshot.*,
│                              # majadu-api.container.v1, env-target.v1
├── deploy/                    # deployed-version, last-release.json
├── backups/                   # mode 700; daily dump + bm-cutover-*.dump
└── logs/                      # deploy.log, cutover.log, caddy-access.log
```

`/etc/caddy/Caddyfile` imports `/srv/qouver/apps/majadu/caddy/active.caddy`
**inside** the `api.qouver.com` site, replacing the old `/majadu/*` handler. That
site also serves `/hooks`, `/sds`, and `/skyward`; the majadu snippet must not
replace the whole site. The `/majadu` prefix is kept after cutover, so the OIDC
redirect, `PUBLIC_BASE_URL`, and the web client do not change. The one-time steps
(including `skip_log` for `/majadu/s/*` and `/majadu/ws/*`; preflight rejects a
Caddyfile that mentions only the first) are in
`ops/caddy/Caddyfile.api.qouver.com`.

## 2. D-7 checklist

- [ ] The release tag is published and the GitHub Release contains the digest
      `ghcr.io/hidaydev/badminton-match@sha256:…`.
- [ ] Rehearsal T-063 passes and `./task rehearsal check` is green
      (`tools/rehearsal/timings.json` ≤ 30 minutes, restore ≤ 15 minutes, cutover
      window ≤ 10 minutes, `--from` proven).
- [ ] `majadu-prod.env.v1` and `.v2` exist, mode 600, and `bm2` does not contain
      production data yet.
- [ ] `majadu-tools.env` exists, mode 600, owned by the deploy user, and names
      the owner, ETL, source-read and staging-restore roles. The API unit never
      loads it.
- [ ] `ghcr-token` (if used) is mode 600 and can `podman pull` the release digest.
- [ ] `alert.env` contains a webhook, or there is a deliberate decision that
      alerts only land in the journal.
- [ ] Disk capacity ≥ 3× the size of `bm` (dump + `bm2` + WAL).
- [ ] The D-3 rehearsal on the VPS is scheduled as an **announced maintenance
      window**, not a sudden downtime.
- [ ] Communication plan: who is told when maintenance starts and when it ends.

## 3. D-3: rehearsal on the VPS (announced maintenance window)

Run on the real VPS because Quadlet and Caddy are not available on the dev
machine. The harness is `tools/rehearsal/`; read the README there before
running it.

1. Announce the maintenance window (start + expected finish).
2. Make sure `bm_staging` contains a staging copy (`backup.sh --tag cutover` then
   `restore.sh --target bm_staging --recreate --dsn "$MAJADU_CUTOVER_RESTORE_DSN"`,
   with the DSN read from `env/majadu-tools.env`).
3. Prepare two rehearsal env files (`v1.env`, `v2.env`, mode 600) from the
   templates in `ops/env/`. `bm2_rehearsal` is recreated by the harness, so it
   needs no preparation.
4. `./task rehearsal run --version v<release> --dry-run`: inspect the sandbox,
   units, Caddy site, and the commands that will run.
5. `MAJADU_REHEARSAL_CONFIRM=yes ./task rehearsal run --version v<release>`:
   the harness runs cutover, rollback, then proves
   `--from restore-staging`, and writes `tools/rehearsal/timings.json`.
6. `./task rehearsal check` must be green; commit `timings.json`.
7. `./task rehearsal clean --drop-databases`.
8. Announce the rehearsal result (actual duration) in the same channel.

If the rehearsal fails, the D-day cutover is **postponed**; there is no "let's
just try it on production".

## 4. D-1

- [ ] Make sure there are no unreleased schema changes on `main`.
- [ ] Make sure `VERSION` on `main` equals the release tag that will be used.
- [ ] Backfill the v1 data still needed (scores, draft sessions) **before** the
      dump; once v1 is shut down there are no more writes.
- [ ] Check `curl -fsS https://api.qouver.com/healthz` (v1) and one old share
      link to establish the baseline.
- [ ] Record the v1 row counts that will be compared after ETL:
      players, sessions, games, tournaments.
- [ ] Prepare a second SSH session to watch
      `journalctl --user -u majadu-api -f` and the Caddy log.

## 5. D-day

All commands are run over SSH to the VPS as the app owner, from
`/srv/qouver/apps/majadu`.

1. **Announce that maintenance starts.** Note the start time.
2. **Run the cutover** (a single command; the script holds the same `flock` as
   deploy, so a deploy that arrives mid-way waits):

   ```sh
   MAJADU_OWNER_SUB='<google-sub>' MAJADU_OWNER_EMAIL='<email>' \
     sudo -E /srv/qouver/apps/majadu/scripts/cutover.sh --version v2.0.0
   ```

   `--version` must be a version whose release already exists. The script stops
   on its own if `cutover_state.completed_at` is already filled.

3. The sequence the script runs (do not do it by hand except to resume):

   | Step | What happens | Signal |
   |---|---|---|
   | `preflight` | check tools, pull the release digest, tag `:release`, copy the Caddy snippet | log “release vX resolves to” |
   | `preserve-v1` | tag `:v1-final` from the live v1 container, verify the ID, save the unit + env target | `v1-final.digest` written |
   | `maintenance` | Caddy → `site-maintenance.caddy` (`caddy validate` first) | site 503 + `Retry-After` |
   | `stop-v1` | `systemctl --user stop` + `disable` | v1 unit `inactive (dead)` and `disabled` |
   | `snapshot` | `backup.sh --tag cutover`, sha256 recorded | `backups/bm-cutover-*.dump` |
   | `restore-staging` | dump → `bm_staging` with `MAJADU_CUTOVER_RESTORE_DSN` | `restore: done` |
   | `prepare-bm2` | roles, migrations, seed, `ownerseed` with `MAJADU_OWNER_DSN` | `dbtools: migrated 26 file(s)` |
   | `import` | ETL from `MAJADU_ETL_SOURCE_DSN` into `MAJADU_ETL_DSN`, then `verify` | `problems: 0` |
   | `state` | fill `cutover_state`, switch env to `.v2` | `env now points at v2` |
   | `start` | `:release` → `:local`, enable + start v2 | unit `active (running)` |
   | `site` | Caddy → `site-v2.caddy` | site returns 200 |
   | `readyz` | poll `/readyz` for 90 seconds | `{"status":"ok"}` |
   | `smoke` | 6 behaviour checks | `smoke: all checks passed` |
   | `finish` | `completed_at = now()` | `cutover vX complete` |

4. **Manual verification after the script finishes:**
   - `curl -fsS https://api.qouver.com/readyz` → 200.
   - `curl -fsS https://api.qouver.com/version` → the new version.
   - Log in with Google as `platform_owner`, open one session, one leaderboard.
   - One **new** share link (`/s/{code}`) opens without login. v1 links already
     in circulation (`/s/{sessionId}`) still resolve as long as that session
     still has a live link: `modules/share/store.nim:102-110` accepts a UUID in
     place of the code. Such a link dies too once the link is revoked; the
     rollback consequence is in §7.
   - Enable the timers **after** `MAJADU_PG_DSN` points at `bm2`, one at a time:
     `systemctl --user enable --now majadu-snapshot.timer majadu-ingest.timer
     majadu-janitor.timer majadu-readyz.timer majadu-rotate-log.timer`, then
     `systemctl --user list-timers` must show all six. Deploy only
     installs the unit files, it never enables timers.
     `majadu-audit-retention.timer` reads `MAJADU_AUDIT_DSN` from the env file and
     runs monthly; `majadu-ingest.timer` rates approved sessions every
     30 minutes; `majadu-readyz.timer` hits `/readyz` every 5 minutes and
     `majadu-rotate-log.timer` rotates logs hourly. Both only depend
     on the host (not the schema), but `majadu-readyz` is deliberately only enabled
     here: before cutover port 8080 belongs to v1.
   - `psql "$OWNER_DSN" -c "select * from platform.cutover_state"` → one row,
     `completed_at` filled, `rows_imported` matches the `bm_staging` count.

5. **Announce completion.** Note the finish time and actual duration.

## 6. If it fails

The script stops with exit ≠ 0 and `cutover.step` points at the last step.
Pick one, not both:

**A. Continue from the failing step**: only if the cause is clear and already
fixed (for example a wrong role password):

```sh
/srv/qouver/apps/majadu/scripts/cutover.sh --version v2.0.0 --from <step>
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
printed in the error message and in the log. Add `--drop-bm2` if the bm2
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

## 7. Consequences that must be announced on rollback

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
  is in `cutover/cutover.state.json`.
- **`bm` does not change** during cutover or rollback: it is only read.

## 8. D+1

- [ ] `/readyz` green for 24 hours; no unexpected restarts
      (`systemctl --user status majadu-api`).
- [ ] `cutover_state.rows_imported` still matches the `bm_staging` count
      (checker cron or manual).
- [ ] No `majadu-alert@` in the journal.
- [ ] The daily `bm2` backup runs and can be read (`pg_restore --list`).
- [ ] The first session created by a real user shows up on the leaderboard.
- [ ] `rating.snapshots` gained yesterday's date
      (`select max(taken_on) from rating.snapshots`), and the arrows on the
      board use that snapshot.
- [ ] Record any deviation (numbers, UI, login) in the incident note if there is
      one.

## 9. D+30

- [ ] `bm` stays read-only; the `bm2_*` roles cannot `CONNECT` to it
      (`ops/db/roles.sql` already enforces this with assertions).
- [ ] The daily `bm` dump stops; keep one final dump outside the rotation.
- [ ] `:v1-final` is kept until T-082: archive it as a tarball
      (`podman save`) **before** the tag is removed, then delete it together
      with the Go decommission.
- [ ] Review whether `majadu-prod.env.v1` and the v1 `ops/scripts` are still
      needed; do not delete `:v1-final` earlier than 30 days.

## 10. What is not yet proven until the D-3 rehearsal

- `cutover.sh`, `rollback.sh`, and `deploy-vps.sh` have never been run on
  this VPS.
- `caddy validate` has only been run on the files created in the repo, not on
  the live Caddy.
- Quadlet (`StartLimit*`, `MemoryMax`, `OnFailure`) has not been parsed by a
  real systemd.
- The durations in §5 are targets, not measurements; the `timings.json` from
  the rehearsal replaces them.