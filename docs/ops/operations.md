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
| GHCR (`ghcr.io`) | Release image registry | Repo owner | Scoped `read:packages` token in `/srv/qouver/apps/majadu/env/ghcr-token`, mode 600; the release workflow pushes with the built-in `GITHUB_TOKEN` |
| Database `bm2` | Production data | API process (`bm2_app`), ETL (`bm2_etl`), schema owner (`bm2_owner`) | Password only in `/srv/qouver/apps/majadu/env/`, directory mode `700` |

Rules that bind this list:

- MFA is required on Google, GitHub, and the VPS panel. Without MFA, one leaked
  password means the whole list above leaks with it.
- Credentials never enter the repository. The repo only contains examples:
  `ops/env/prod.env.example` for the API unit and
  `ops/env/prod-tools.env.example` for the deploy, cutover and one-shot job
  units. On the VPS they are two files, both mode 600, in a directory that is
  mode 700 and owned by the deploy user. `majadu-prod.env` is the only
  `EnvironmentFile` of the API unit; `majadu-tools.env` is the only env file for
  `majadu-ingest`, `majadu-janitor`, `majadu-snapshot` and
  `majadu-audit-retention`, and for the deploy and cutover scripts. `deploy-vps.sh`
  refuses an API file that carries an owner or tool DSN, a tool file that omits
  `MAJADU_PG_DSN` or carries the OIDC client secret or the share-code keyring,
  and an `env` directory owned by anyone but the deploy user.
- Accounts no longer in use are revoked in all three places: GitHub, the VPS
  panel, and `platform_owner` (through `./task opstoken`/the CLI, not manual SQL).
- Database roles are separated: the app has no right to delete `account.audit`,
  and only `bm2_owner` runs the audit cleaner.

### Credential rotation

Every credential is issued for 90 days and rotated by the owner, on a calendar
entry, not when something breaks. The deploy reads the files by name; the
rotation is a file replace plus the restart or re-login in the table.

| Credential | File on the VPS | Rotate by | Verify after | Last rotated | Next due |
|---|---|---|---|---|---|
| GHCR read token | `env/ghcr-token` | issue a new `read:packages` token, replace the file, mode 600 | `podman login ghcr.io -u <user> --password-stdin < env/ghcr-token` | not recorded | not recorded |
| GitHub CI token (RC) | `env/github-token` | new fine-grained token, `actions: read`, replace the file, mode 600 | `env/github-token` is read by the RC CI gate on the next push | not recorded | not recorded |
| Vercel token | `env/vercel-token` | new token in the Vercel account, replace the file, mode 600 | `VERCEL_TOKEN=$(cat env/vercel-token) vercel whoami` | not recorded | not recorded |
| Database passwords | `env/majadu-prod.env`, `env/majadu-tools.env`, `env/majadu-rc*.env` | `alter role ... password` for each role, then update every file that names it (`MAJADU_PG_DSN` is in both prod files) | `./task ci` against the DSN, or `curl /readyz` after `systemctl --user restart majadu-api` | not recorded | not recorded |
| Alert webhook | `env/alert.env` | new webhook URL in the provider, replace the file, mode 600 | `systemctl --user start majadu-alert@rotation-test.service` and look for the delivery | not recorded | not recorded |
| Cosign public key | `env/cosign.pub` | follows the signing key, not a secret | `cosign verify --key env/cosign.pub <image>` | not recorded | not recorded |

The two date columns are the register, not a pointer to one: a credential whose
row still says `not recorded` has no evidence that it was ever rotated, which is
the finding. Fill both cells in the same edit as the rotation, and set `Next due`
90 days out.

Rotation dates used to live only in the private incident log; `deploy-vps.sh`
refuses to run when any regular file under `env/` is not mode 600 or 400, so a
copy made with the wrong umask fails the next deploy instead of sitting there
readable.

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

### Severity

The level decides who is woken and how fast. Assign it in the first minute; it
is cheaper to lower it later than to explain a delay.

| Level | Trigger | Examples | Response time | Containment target | Who is told, and by when | User notice |
|---|---|---|---|---|---|---|
| SEV-1 | the external uptime checker or `majadu-readyz.timer` reports the public origin down; `/readyz` answers 503; data is lost or corrupted; personal data may be exposed | production API down or serving 5xx to everyone; data loss or corruption; a personal-data exposure; the database unreachable | 15 minutes | 1 hour | repository owner immediately, by the alert webhook and a phone call to self; the community channel within 1 hour of a confirmed user impact | within 72 hours if personal data was involved |
| SEV-2 | a core flow fails for one community while the origin still answers 200, or a release was rolled back | a core flow broken for one community (scores cannot be saved, login fails for one provider path); a release rollback used | 1 hour | 4 hours | repository owner the same day, by the alert webhook or a phone call to self; the affected community's channel within 4 hours when that community is known | if a community lost data or a feature for more than a day |
| SEV-3 | a timer or check is red while users are not blocked, or a non-core report | degraded but working (slow reads, a badge missing, the RC instance down) | next working day | next working day | repository owner at the next check, written in the note; no community notice | not required |
| SEV-4 | cosmetic, documentation, or one person's workaround | cosmetic, documentation, a single person's workaround | next release | next release | nobody; the note is the record | not required |

Response time is the clock to the first action on the note (severity assigned,
status checked), not to a fix; the containment target is the separate clock. A
trigger promotes an incident to that level on its own; nothing is lowered until
the trigger no longer holds, and the lowering is written in the note.

### Notification

The severity decides who hears about it and when. A SEV-1 goes to the community
channel within one hour of a confirmed user impact, in plain words: what is not
working, since when, and whether scores already entered are safe. A SEV-2 goes
to the affected community's channel within four hours once that community is
known; if it is not known by then, the note says so and the owner decides who to
ask. SEV-3 and SEV-4 carry no community notice. Personal data changes the answer
for every level: if it may be involved, the affected people are told within 72
hours and named data is stated, as the first-hour checklist requires, and that
timeline is legal, not technical, so it is not shortened to save a day or
skipped because the cause is already fixed.

The owner is told through the alert webhook and, for SEV-1, a phone call to
self. What stays in the private note is everything the community does not need:
the trigger, the times, the commands run, what failed, the accounts and hosts
involved, the image restored by a rollback, and the prevention. Notes are still
stored in `.local/incidents/`, never in the public repository; a public
changelog line says what changed for users, and it points to no note.

### First hour

1. Assign the severity from the table above and write it in the note.
2. Stop the bleeding before diagnosing: `systemctl --user status majadu-api`,
   the last release in `deploy/last-release.json`, and
   `ops/scripts/release-rollback.sh` if the last release is the cause.
3. Write down the time of every step as it happens; the note is the evidence,
   not a reconstruction.
4. If personal data may be involved, preserve the logs and the audit digest
   before rotating anything, and treat the next step as legal, not technical:
   tell the affected people within 72 hours, name the data, and record the
   decision even when the answer is "no notice needed".
5. After containment, write the prevention with its artifact (commit, config,
   test). "Be more careful" is not prevention.

### Exercises

One tabletop exercise per quarter, recorded as an incident note with the date
and the scenario (for example "the VPS disk is full at 02:00" or "the Vercel
account is suspended"). It changes behaviour, so it is summarised in
`CHANGELOG.md`. An exercise that finds the runbook wrong updates the runbook in
the same change.

| Exercise | Date | Scenario | Participants (role) | Outcome recorded in |
|---|---|---|---|---|
| Q4 2026 tabletop, scheduled | 2026-12-11 (Friday), 20:00 Asia/Jakarta | a share link to one community's score history is reported on the public issue tracker by a stranger, at 21:30, ninety minutes after the exercise starts, and the reporter pastes two player names | repository owner as incident commander, operator and scribe, the three roles written separately even though one person fills them; the same owner 48 hours later as reviewer, reading only the note and the runbook, not the shell history | `.local/incidents/2026-12-11-tabletop-share-link.md`, copied to `MAJADU_BACKUP_DIR/incidents/` at close, and a `CHANGELOG.md` line only if the exercise changes behaviour |

The entry above is the schedule, not a record: it is replaced by the note's own
date and finding once the exercise runs. The scenario is chosen to exercise the
parts that a solo operator cannot improvise: assigning SEV-1 from a report
rather than an alert, the 72-hour personal-data decision, and whether the private
log can be written while the public answer is being prepared. A cancelled
exercise keeps its row and gets the reason in the Outcome column rather than
being deleted.

Filling rules:

- **Impact** names specific data, not "the system". A correct example:
  "the score history of 12 sessions in community X was readable through a revoked
  link", not "data leak".
- **Actions** records times, not narrative. If a rollback was used, name the
  image restored.
- **Prevention** must have an artifact: a commit, a configuration change, or a
  new test. "I will be more careful" is not prevention.
- Notes are stored in `.local/incidents/` (not in the public repo) and
  summarized in the release changelog if they touch users. At close, the note
  is copied into `MAJADU_BACKUP_DIR/incidents/` on the host, so the learning
  record leaves the laptop with the dumps instead of dying with it.

## 3. Routine checks

| When | What | Command |
|---|---|---|
| Every deploy | Process health; `deploy-vps.sh` runs migrations before the restart | `curl -fsS http://127.0.0.1:8080/readyz` |
| Every 5 minutes | `/readyz` is watched by `majadu-readyz.timer`; a failure triggers `majadu-alert@`. `majadu-host-check.timer` watches free disk, OOM kills and the running image | `systemctl --user list-timers majadu-readyz.timer majadu-host-check.timer` |
| Every ten minutes | Logs are rotated by `majadu-rotate-log.timer` (rename, gzip, delete >14 days, disk guard) | `ls -l /srv/qouver/apps/majadu/logs` |
| Daily | Disk and memory headroom; no undelivered alerts | `df -h /srv && systemctl --user show majadu-api -p NRestarts && ls -l /srv/qouver/apps/majadu/logs/alert-dead-letter.log` |
| Monthly | Migrations and seeds still match the schema | `./task ci` on a dev machine with `MAJADU_PG_DSN` |
| Yearly | The access list above is still accurate | review by hand, revoke what is unused |
| Once, after the cutover | The pre-code `/s/{sessionId}` shortcut still answers for rows that existed before codes | `./task sharekeys retire-legacy --older-than 30 --dry-run`, then without `--dry-run` |

`deploy-vps.sh` runs `dbtools migrate` then `dbtools verify` from the newly
pulled image, using `MAJADU_OWNER_DSN` from `majadu-tools.env`, before the unit
is restarted. The API unit loads only `majadu-prod.env`; it never sees the owner
or ETL credential, and the one-shot job units load only `majadu-tools.env`, so
neither side sees the other's secrets. A failure
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
| `majadu-host-check.timer` | VPS | at least `MIN_FREE_MB` (2048) is free, the container was not OOM-killed, and it runs the `:local` image |
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
`journalctl --disk-usage`. The API writes its access line to stdout and nothing
to disk, so the journal is the only copy; the units mount no log volume. The
rotate timer still covers the operator logs (deploy, cutover, rollback) under
`/srv/qouver/apps/majadu/logs`, and `host-check.sh` pages when the volume is
close to full or the container was killed for memory. It also pages when no
`SystemMaxUse` is set in `/etc/systemd/journald.conf` or its drop-in directory:
the install is a one-time root step that nothing in the deploy path can repeat,
so an uncapped journal is a slow disk fill nobody notices until Postgres is
down.

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
  --requests 100000 --concurrency 50 --pid "$(pgrep -f majadu-api | head -1)"
```

The same harness has a self-contained form that needs no host and no shared
database: `--local` creates `bm2_load_test`, migrates and seeds it, builds and
boots the API on it, runs the load with the process id so the report carries
RSS, and drops the database on the way out.

```sh
./task loadtest --local --requests 20000 --concurrency 50 --out load.json
```

That is the repeatable baseline: it answers "did this commit make the read path
slower or the process bigger" without a VPS, and it is the run to quote when the
question is a regression rather than the host's ceiling. The `--local` numbers
are a laptop, so they do not replace the host run: the 512 MB ceiling and the
500-watcher fan-out are only exercised on the host.

The report is one JSON object: p50/p95/p99 and the failure count for the HTTP
half, the WebSocket opened/error counts, and, when `--pid` names the API
process, the resident set size before, after and at its peak. Record the whole
object; a latency number without the memory number cannot distinguish a slow
reply from a process about to hit the 512 MB limit.

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
  and never published). The endpoint stays unpublished, and a host agent
  scrapes it through the `node_exporter` textfile collector:

  ```ini
  # ~/.config/systemd/user/majadu-metrics-scrape.service
  [Unit]
  Description=Majadu metrics for the node_exporter textfile collector
  [Service]
  Type=oneshot
  ExecStart=/usr/bin/podman exec majadu-api /usr/bin/curl -fsS \
    http://127.0.0.1:9090/metrics
  StandardOutput=file:/srv/qouver/apps/majadu/metrics/majadu.prom

  # ~/.config/systemd/user/majadu-metrics-scrape.timer
  [Unit]
  Description=Scrape the Majadu metrics port once a minute
  [Timer]
  OnCalendar=*:0/1
  [Install]
  WantedBy=timers.target
  ```

  `node_exporter` runs with
  `--collector.textfile.directory=/srv/qouver/apps/majadu/metrics` and
  Prometheus scrapes that exporter, so the target is `127.0.0.1:9100` while the
  API port remains loopback-only. Without the agent the supported query is
  still manual:

  ```sh
  podman exec majadu-api curl -fsS http://127.0.0.1:9090/metrics \
    | grep '^http_requests_total'
  ```

  That line, plus the structured `"msg":"request"` access log, is the current
  answer to "request rate and 5xx for the last hour".

  Authentication and authorization refusals are the signal SEC-02 exists for,
  and they are both counted and audited: every `403` from a community route
  writes one `account.audit` row with `action = 'authz.denied'` (actor, role,
  route template, request id), and the counter below is the cheap series to
  alert on before reading those rows:

  ```yaml
  # /srv/qouver/apps/majadu/env/alert-rules.yml, loaded by Prometheus
  groups:
    - name: majadu
      rules:
        - alert: MajaduAuthRefusals
          # Every refusal, anonymous or signed in: a script that probes share
          # codes or mints logins shows up here first.
          expr: sum(rate(http_requests_total{status=~"401|403"}[5m])) > 0.5
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "sustained 401/403 responses on the Majadu API"
            description: >-
              Refusals are above half a request per second. Check for a scanner
              or a broken client before assuming an attack.
        - alert: MajaduAuthzDenied
          # The sharper one: a signed-in principal refused on a community route
          # is what enumeration by a member looks like, and every 403 has an
          # authz.denied row to read.
          expr: sum(rate(http_requests_total{status="403"}[10m])) > 0.05
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "sustained 403 responses on the Majadu API"
            description: >-
              A signed-in principal is being refused repeatedly. Read
              account.audit where action = 'authz.denied' for the actor and the
              route template, and correlate by request_id with the access log.
  ```

  The wider rule can be noisy on a public API (a mistyped URL answers 401), so
  the second rule narrows the same series to 403 and is the one to act on.

### 4.1 Metrics scrape checklist

The registry is a Prometheus text exposition on the loopback listener. Until
the textfile agent above is installed it is read by hand, so these are the
series an operator reads during an incident, and the query each one answers:

| Series | Answers |
|---|---|
| `http_requests_total{method,route,status}` | which route is 5xx-ing right now |
| `http_requests_total{status="403"}` | whether a signed-in principal is being refused; pair it with `account.audit` where `action = 'authz.denied'` |
| `http_request_duration_seconds_bucket{route,le}` | p95 latency of one route (`histogram_quantile` over the buckets) |
| `http_request_duration_seconds_sum` / `_count` | mean latency of one route |
| `db_pool_available` / `db_pool_in_use` / `db_pool_size` | whether the pool is the reason requests queue |
| `identity_resolution{source}` | whether anonymous traffic collapsed into one `peer` bucket behind the CDN |
| `share_key_problems_total` | a live share link references a `key_id` `SHARE_CODE_KEYS` no longer holds (restore the key, do not issue a new link) |

Read them with one command, from the host:

```sh
podman exec majadu-api curl -fsS http://127.0.0.1:9090/metrics \
  | grep -E '^(http_request|db_pool|identity_resolution|share_key_problems)'
```

For a latency answer, keep the buckets and compute the quantile:

```sh
podman exec majadu-api curl -fsS http://127.0.0.1:9090/metrics \
  | grep '^http_request_duration_seconds_bucket{route="/c/{slug}/sessions"'
```

A 5xx is joined to its request by id: the problem body carries `request_id`,
the `"msg":"request"` access line carries the same value, and the audit rows
written while serving it carry it too, so `journalctl | grep <request_id>`
reconstructs the request. Once the textfile agent above is installed, those
four series are the minimum the dashboard needs; nothing else in the registry is
required to answer "is it slow, is it failing, is it the pool".