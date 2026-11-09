# Release

The v2 release runbook: how a version is made, what must be right before it is
declared done, and how to go back to the previous release on a functional
regression (not during cutover; for that, see `docs/ops/cutover.md`).

Status: the build flow and workflow are in the repo, but they have **never been
run end to end on the VPS**. The parts that are not yet proven are named in §6;
do not consider them tested.

## 1. Source of truth

| Artifact | Contents | Used by |
|---|---|---|
| `VERSION` | the version under development | `deploy-vps.sh` (deploy gate), `apps/api/src/app.nim` (`appVersion`) |
| `CHANGELOG.md` | per-version sections from Conventional Commits | the GitHub release |
| tag `v<version>` | SSH-signed, created by the operator | `.github/workflows/release.yml` |
| image `ghcr.io/hidaydev/badminton-match:v<version>` | one build per tag | `deploy-vps.sh` (pull by digest) |
| `digest: sha256:…` line in the GitHub Release body | the only digest the deploy accepts, signed by `cosign` | `deploy-vps.sh`, `cutover.sh` |
| `cosign.pub` in `env/` | verifies the image signature before the pull | `deploy-vps.sh`, `cutover.sh` |

The release body begins with the tag message, which is free text. The deploy
accepts exactly one `digest: sha256:…` line and refuses the release when any
other digest-shaped string appears in the body (for example in the tag message).
The signature is checked with `cosign verify --key env/cosign.pub` before
`podman pull`.

`deploy-vps.sh` decides to deploy from `VERSION`, not from the tag: a commit that
bumps `VERSION` is a release, a documentation commit is not. That is why the tag
must already be published **and** its image must already exist before `main` is
pushed.

## 2. Release sequence

1. `./task release`: dry run. It prints the bump, the changelog section, and the
   following commands; it writes or tags nothing.
2. `./task release --apply`: writes `VERSION`, `CHANGELOG.md`, and
   `.cache/release/v<version>.md` (tag message source). It only runs if the
   working tree is clean and the last tag matches `VERSION`.
3. Commit `chore(release): v<version>`.
4. `git tag -s -F .cache/release/v<version>.md v<version>`.
5. **Push the tag first**, then `main`:

   ```sh
   git push origin refs/tags/v<version>
   git push origin main
   ```

   The tag triggers `release.yml` (verify → image → publish). `main` triggers the
   deploy webhook. The reverse order makes the deploy run before the image
   exists; the deploy script will fail at the `resolve-digest` step, not silently
   use another image.
6. Wait for `release.yml` to go green and record the digest from the GitHub
   Release body. `release.yml` never creates or moves a tag; the tag always comes
   from the operator.

## 3. What the deploy does

After the cutover gate (`MAJADU_PG_DSN` points at `bm2`) and the version check,
the sequence is:

1. `git fetch origin main` + `git reset --hard origin/main`.
2. Resolve the digest from the GitHub Release, `podman pull` that digest.
3. **`dbtools migrate` + `dbtools verify`** from the newly pulled image, using
   `MAJADU_OWNER_DSN` from `env/majadu-tools.env` (the API unit loads only
   `env/majadu-prod.env` and never sees that credential). A failure here = the
   release is not installed,
   `:local`/`:prev` are not touched, the old service keeps running.
4. Tag rotation: `:local` → `:prev`, the new image → `:local`.
5. Sync the systemd units and operator scripts from the repo.
6. Restart the unit, wait for `/readyz` (60 seconds). Failure → `:prev` is made
   `:local` and restarted.
7. Run `scripts/smoke.sh <health_url> <version>`, which pins `/version` to the
   version just pulled. Failure → the release is not recorded, so the next push
   repeats the same version.
8. Make sure the container really uses the `:local` image, then write
   `deploy/deployed-version` and `deploy/last-release.json`
   (`version`, `commit`, `digest`, `schema`, `at`).

A failed attempt writes `deploy/last-attempt.json` with the same identity fields
of the release that is still serving; it never overwrites `last-release.json`.
That file stays the rollback input.

## 4. Exit criteria

A release is not done until all six are true:

1. **Digest matches.** `deploy/last-release.json` records the digest used;
   its value must equal the digest in the GitHub Release body, and
   `podman inspect --format '{{.Image}}' majadu-api` must equal
   `podman image inspect --format '{{.Id}}' localhost/majadu-api:local`
   (the deploy already checks this last pair in the `verify-image` step).
2. **Version matches.** `curl -fsS http://127.0.0.1:8080/version` reports the
   version **and** the commit released (`-d:appVersion`/`-d:appCommit` from
   `apps/api/Dockerfile`, `--build-arg` from `release.yml`). The deploy itself
   already runs `smoke.sh`, which checks the version; check by hand only if that
   gate was skipped.
3. **24 hours without a restart loop.**
   `systemctl --user show majadu-api -p NRestarts` stays 0 and the journal does
   not contain `StartLimit`/`Scheduled restart`.
4. **No new 5xx.** The counter is on an internal loopback listener
   (`MAJADU_METRICS_PORT`, not published); after 24 hours, read
   `http_requests_total` from inside the container and the unit's structured
   access log (`"msg":"request"`) for routes/statuses that changed.
5. **Production smoke passes.**
   `ops/scripts/smoke.sh http://127.0.0.1:8080 <version>`: `/version`,
   `/healthz`, `/readyz`, `/metrics` 404, a foreign share code 404, `/auth/me` 401.
   The deploy runs it itself after `/readyz` goes green (step 7 in §3); if that
   gate fails, `deploy/deployed-version` is not written and the release is retried
   on the next push.
6. **`:v1-final` has a deletion date and an archived digest.** That tag is never
   deleted by the deploy (`podman image prune -f` only drops untagged images);
   delete it by hand after that date, with the digest recorded in the release
   notes.

If any of them fails, use §5, do not patch on the server.

## 5. Rollback on functional regression (v2 → `:prev`)

This differs from `ops/scripts/rollback.sh`, which returns production to **v1**
and deletes `cutover_state`. For a regression in a v2 release, the right image
is `:prev`.

- **Automatic**: done by the deploy itself if `/readyz` fails: `:prev` is made
  `:local`, the service is restarted, the log records
  `rolled back: :prev answers /readyz`.
- **Manual**, if the regression only shows up after the gate went green:

  ```sh
  /srv/qouver/apps/majadu/scripts/release-rollback.sh
  ```

  The script reads `deploy/last-release.json` (and the `.prev` record the deploy
  keeps), requires `:prev` to exist, retags it, restarts the unit, waits for
  `/readyz`, and refuses a `/version` that does not report the previous release.
  It then rewrites `deploy/deployed-version` and `last-release.json`, so the next
  push is not skipped as "already live". It pages through
  `majadu-alert@release-rollback.service` if any step fails.

  Do not use `rollback.sh` for this: that script returns production to v1 and
  deletes cutover state.

The schema is not rolled back: `:prev` must be able to serve the schema already
migrated by the new release. The rules are in §6.

## 6. Migrations: the expand/contract rules

The deploy runs migrations automatically, so every release must satisfy:

- **Add only** within a single release: new tables, nullable or
  `NOT NULL DEFAULT` columns, new indexes. Do not `rename`, `drop`, or change the
  type of a column that `:prev` still writes.
- **`CONCURRENTLY` indexes are done by hand, outside migrations.** `dbtools migrate`
  runs each file inside a single transaction, and PostgreSQL refuses
  `create index concurrently` there. Build that index as an operator step
  before the deploy; the migration then only contains `create index if not exists`,
  which becomes a no-op.
- **Files with a `-- contract` header are rejected by default.** A removal may
  only run through `dbtools migrate --allow-contract`, one release after the
  deploy that stopped using the old shape has become `:prev`.
- **Idempotent seeds** (`insert … on conflict do nothing`). The deploy does not
  call `dbtools seed`; new seeds only arrive through `cutover.sh` or the operator.
- **`/readyz` is not a substitute for `verify`.** Readiness only checks that
  relations exist (`to_regclass`); a missing column or seed still passes with 200.
  What proves the schema is `dbtools verify` in the deploy step.

`deploy/last-release.json` stores `schema` (the name of the last migration file),
and the deploy log records `schema verified at <file>`. On rollback to `:prev`,
the log line names that schema: a `:prev` that is incompatible will fail at
readiness, not silently write wrong data.

## 7. What is not yet proven

- There is no real execution on the VPS: `podman pull`/`run`, `systemctl --user`,
  Quadlet, and Caddy are not available on the dev machine. Everything above is
  proven only with `bash -n`, code reading, and the T-063 rehearsal test, not
  production.
- `dbtools migrate` inside the container uses the `qouver` network and the
  `bm2_owner` role; that combination has never been run on the VPS.
- Two concurrent release queues have not been tested; `flock` holds the second
  for up to 900 seconds and then gives up.