# Operations

This document answers two things that must not need looking up while an incident
is in progress: who holds access, and the format of the incident note. The
cutover procedure has its own document (`docs/ops/cutover.md`), as do releases
(`docs/ops/release.md`) and Google login (`docs/ops/google-oauth.md`).

## 1. Access holders

This instance is run by one person (solo developer). This table is the complete
list of access holders; adding a row means adding attack surface.

| Asset | Used for | Holder | Protection |
|---|---|---|---|
| Google account `platform_owner` | Logging in to the app as the platform owner | Repo owner | MFA required, device separate from the social account |
| GitHub `hidaydev` | Repo, Actions, CI secrets, security advisories | Repo owner | MFA required (passkey/TOTP), no password-only login |
| VPS Qouver (`qouver.com`) | SSH to the host, `systemctl --user`, rootless Podman, `/srv/qouver/apps/majadu` | Repo owner | SSH keys only, password login disabled, MFA on the provider panel |
| GHCR (`ghcr.io`) | Release image registry | Repo owner | Scoped access token `read:packages`, stored in a CI secret |
| Database `bm2` | Production data | API process (`bm2_app`), ETL (`bm2_etl`), schema owner (`bm2_owner`) | Password only in `/srv/qouver/apps/majadu/env/`, directory mode `700` |

Rules that bind this list:

- MFA is required on Google, GitHub, and the VPS panel. Without MFA, one leaked
  password means the whole list above leaks with it.
- Credentials never enter the repository. The repo only contains examples:
  `ops/env/prod.env.example` for the API unit and
  `ops/env/prod-tools.env.example` for the deploy and cutover tools. On the VPS
  they are two files, both mode 600 and owned by the deploy user;
  `majadu-tools.env` holds the owner and ETL roles and is never an
  `EnvironmentFile` of the API unit.
- Accounts no longer in use are revoked in all three places: GitHub, the VPS
  panel, and `platform_owner` (through `./task opstoken`/the CLI, not manual SQL).
- Database roles are separated: the app has no right to delete `account.audit`,
  and only `bm2_owner` runs the audit cleaner.

### Credential rotation

Every credential is issued for 90 days and rotated by the owner, on a calendar
entry, not when something breaks. The deploy reads the files by name; the
rotation is a file replace plus the restart or re-login in the table.

| Credential | File on the VPS | Rotate by | Verify after |
|---|---|---|---|
| GHCR read token | `env/ghcr-token` | issue a new `read:packages` token, replace the file, mode 600 | `podman login ghcr.io -u <user> --password-stdin < env/ghcr-token` |
| GitHub CI token (RC) | `env/github-token` | new fine-grained token, `actions: read`, replace the file, mode 600 | `env/github-token` is read by the RC CI gate on the next push |
| Vercel token | `env/vercel-token` | new token in the Vercel account, replace the file, mode 600 | `VERCEL_TOKEN=$(cat env/vercel-token) vercel whoami` |
| Database passwords | `env/majadu-prod.env`, `env/majadu-tools.env`, `env/majadu-rc*.env` | `alter role ... password` for each role, then update both files | `./task ci` against the DSN, or `curl /readyz` after `systemctl --user restart majadu-api` |
| Alert webhook | `env/alert.env` | new webhook URL in the provider, replace the file, mode 600 | `systemctl --user start majadu-alert@rotation-test.service` and look for the delivery |
| Cosign public key | `env/cosign.pub` | follows the signing key, not a secret | `cosign verify --key env/cosign.pub <image>` |

Rotation dates are recorded in the private incident log next to the access
list; a token older than 90 days is a finding. `deploy-vps.sh` refuses to run
when any regular file under `env/` is not mode 600 or 400, so a copy made with
the wrong umask fails the next deploy instead of sitting there readable.

## 2. Incidents

One incident, one note, five fields. There is no other format; a long report
without these five fields cannot be acted on.

```markdown
### Incident YYYY-MM-DD: <short title>

- **Detection**: how it was noticed (alert, report, self-found), the time, and
  the first signal that appeared.
- **Impact**: which data or function is affected, who is hit, for how long. If
  it is not known yet, write "unknown" and update it.
- **Actions**: what was actually done, in order, including what failed.
- **Prevention**: the change that prevents a repeat (code, configuration,
  process), with a commit/PR link.
- **Owner**: one name responsible for closing the follow-up.
```

Filling rules:

- **Impact** names specific data, not "the system". A correct example:
  "the score history of 12 sessions in community X was readable through a revoked
  link", not "data leak".
- **Actions** records times, not narrative. If a rollback was used, name the
  image restored.
- **Prevention** must have an artifact: a commit, a configuration change, or a
  new test. "I will be more careful" is not prevention.
- Notes are stored in `.local/incidents/` (not in the public repo) and
  summarized in the release changelog if they touch users.

## 3. Routine checks

| When | What | Command |
|---|---|---|
| Every deploy | Process health; `deploy-vps.sh` runs migrations before the restart | `curl -fsS http://127.0.0.1:8080/readyz` |
| Every 5 minutes | `/readyz` is watched by `majadu-readyz.timer`; a failure triggers `majadu-alert@` | `systemctl --user list-timers majadu-readyz.timer` |
| Every hour | Logs are rotated by `majadu-rotate-log.timer` (rename + delete >14 days) | `ls -l /srv/qouver/apps/majadu/logs` |
| Daily | The deploy log grows without rotation | `ls -l /srv/qouver/apps/majadu/logs` |
| Monthly | Migrations and seeds still match the schema | `./task ci` on a dev machine with `MAJADU_PG_DSN` |
| Yearly | The access list above is still accurate | review by hand, revoke what is unused |

`deploy-vps.sh` runs `dbtools migrate` then `dbtools verify` from the newly
pulled image, using `MAJADU_OWNER_DSN` from `majadu-tools.env`, before the unit
is restarted. The API unit loads only `majadu-prod.env`; it never sees the owner
or ETL credential. A failure
there aborts the deploy and leaves the old release running; `:local` and `:prev`
are not touched.

`/readyz` itself only answers `503` if the database is unreachable, a required
relation is missing (`to_regclass`), or the snapshot in `platform.cutover_state`
does not match `CUTOVER_SNAPSHOT_SHA256`. Columns or seeds that are not in place
yet are not detected there; what proves the schema is `dbtools verify` in the
deploy step. `503` means "do not send traffic", not "try again".

## 4. Monitoring, alerting and the availability target

Two detectors run on the VPS and one runs outside it. The VPS ones are useful but
they cannot report the failure they are most likely to miss: the host itself.

| Detector | Runs on | What it proves |
|---|---|---|
| `majadu-readyz.timer` | VPS | the API answered `/readyz` in the last five minutes |
| `majadu-deploy-check.timer` | VPS | the latest release reached `deploy/deployed-version` |
| external uptime checker | provider | the public origin answers from outside the VPS |

The external checker is an account-level uptime monitor (the provider's own
service, not a unit in this repository) with two HTTPS checks: `GET
https://api.qouver.com/majadu/readyz` expecting `200`, and `GET
https://majadu.vercel.app/` expecting `200`. Its notification channel is the
account email plus push, deliberately independent of the VPS, the user systemd
manager and the `majadu-alert@` webhook. Configure the checks for a 60 second
interval and a 5 minute alert delay; a check that only runs on the machine it
watches cannot report that the machine is gone.

Availability target: **99.0% per calendar month** for the public API and web
origin (about 7 hours 18 minutes of allowed downtime), excluding announced
maintenance announced in the community channel at least 24 hours ahead. The
target is a single-instance target: the API is one process on one host, so a
host failure is downtime, not a degraded mode.

Journal retention is bounded by `ops/journald/majadu.conf` (200 MB, 30 days).
Install it on the host as described in the file header, then confirm with
`journalctl --disk-usage`.

## 5. Capacity statement

The service is one process on one host. The host measured for this project is
2 vCPU, 7.4 GB RAM and a 512 MB container limit (`ops/systemd/majadu-api.container`).
The configured ceilings are:

| Resource | Ceiling | Source |
|---|---|---|
| concurrent session watchers, process | 500 | `ws.max_watchers_process` |
| concurrent watchers per session | 50 | `ws.max_watchers_per_session` |
| concurrent watchers per address | 20 | `ws.max_watchers_per_ip` |
| requests per minute per route and identity | 300 | `platform.config` seed |
| API memory | 512 MB | `MemoryMax` in the unit |

Those are safety limits, not measurements. The measured capacity is recorded by
the T-074 soak test on the host above, using the committed load test:

```sh
./task loadtest --http https://api.qouver.com/majadu/readyz \
  --requests 100000 --concurrency 50
```

The watcher half needs a file of single-use watcher URLs (`--ws-file`), because
a ticket cannot be replayed. Until that run is recorded here, the 500-watcher
ceiling is a configuration default and the capacity claim is unproven. A run
that reaches 500 watchers and 100,000 requests without a 5xx, a rejected
upgrade or an OOM is the acceptance evidence; a lower measured ceiling is the
number to configure, not the default.

## 6. What is still missing

Being honest about gaps is more useful than a runbook that assumes tools that do
not exist:

- `ops/scripts/{cutover,rollback,backup,restore,smoke}.sh` exist in the repo,
  but have never been run on a real VPS. The D-3 rehearsal (T-063) is what
  proves them; before that, do not consider the rollback path tested.
- Automatic alerts exist at the unit level: `OnFailure=majadu-alert@%N.service`
  on every unit, and `deploy-vps.sh`, `cutover.sh`, and `rollback.sh` call the
  same template on failure. `%N` is the unit name without its type suffix, so
  `majadu-janitor.service` starts `majadu-alert@majadu-janitor.service`; `%n`
  would produce `majadu-alert@majadu-janitor.service.service`, which does not
  exist. The shelltests assert the specifier and the template presence because a
  macOS checkout cannot run systemd; on the host, prove the expansion with
  `systemd-analyze verify ~/.config/systemd/user/majadu-janitor.service` (and
  the other installed units) after a deploy. The alert unit now retries a
  webhook three times with backoff and appends an undelivered message to
  `logs/alert-dead-letter.log`; without
  `/srv/qouver/apps/majadu/env/alert.env` (mode 600) the message only goes to
  the journal, it is not sent off the machine. A red push to `main` and a red
  nightly also post to the same webhook from their `notify` job when
  `MAJADU_ALERT_WEBHOOK` is configured. Journal retention is in the repository
  (`ops/journald/majadu.conf`), but installing it and shipping the journal
  off-host are VPS steps.
- `readyz` used to be just a probe; now `majadu-readyz.timer` hits it every 5
  minutes and a failure becomes an alert. Internal metrics exist on
  `MAJADU_METRICS_PORT` (default 9090, bound to 127.0.0.1 inside the container
  and never published). There is no scrape target or dashboard, so the supported
  query is manual:

  ```sh
  podman exec majadu-api curl -fsS http://127.0.0.1:9090/metrics \
    | grep '^http_requests_total'
  ```

  That line, plus the structured `"msg":"request"` access log, is the current
  answer to "request rate and 5xx for the last hour". A real backend and an
  external checker remain on the roadmap.