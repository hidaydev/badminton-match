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

## 4. What is still missing

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
  the other installed units) after a deploy. Without
  `/srv/qouver/apps/majadu/env/alert.env` (mode 600) the message only goes to
  the journal, it is not sent off the machine. Journal retention and shipping
  the journal off-host are not configured; those are VPS steps, not files in
  this repo.
- `readyz` used to be just a probe; now `majadu-readyz.timer` hits it every 5
  minutes and a failure becomes an alert. Internal metrics (T-062) are still not
  exposed; `/ops/ping` only proves the CLI token is alive.