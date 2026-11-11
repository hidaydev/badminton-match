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
| `.github/allowed_signers` | the public half of the release signing key, one key line; **owned by the owner**, committed by the owner | `git verify-tag` in `release.yml`, `./task ci-guards --release` |
| image `ghcr.io/hidaydev/badminton-match:v<version>` | one build per tag | `deploy-vps.sh` (pull by digest) |
| `digest: sha256:…` line in the GitHub Release body | the only digest the deploy accepts, signed by `cosign` | `deploy-vps.sh`, `cutover.sh` |
| `cosign.pub` in `env/` | verifies the image signature before the pull | `deploy-vps.sh`, `cutover.sh` |

The release body begins with the tag message, which is free text. The deploy
accepts exactly one `digest: sha256:…` line and refuses the release when any
other digest-shaped string appears in the body (for example in the tag message).
The signature is checked with `cosign verify --key env/cosign.pub` before
`podman pull`.

The tag is `v<version>` and nothing else. `VERSION` on this tree is `2.0.0`, so
the tag is `v2.0.0`. The candidate branch carries a pre-release name of its own;
the tag never does, and this repository has no release-candidate tag.
`release.yml` refuses a tag whose name does not match `VERSION` (it fails with
`VERSION is '<VERSION>' but the tag says '<tag>'`), and that is the intended
behaviour: the version that was tested and the version that is released are the
same string.

`deploy-vps.sh` decides to deploy from `VERSION`, not from the tag: a commit that
bumps `VERSION` is a release, a documentation commit is not. A matching
`deploy/deployed-version` is not enough to skip the run: the image `:local` must
exist, the container must be running and `/version` must report the same
version. Anything else deploys again and says which check failed. That is why the tag
must already be published **and** its image must already exist before `main` is
pushed.

## 2. Release sequence

1. `./task release`: dry run. It prints the bump, the changelog section, and the
   following commands; it writes or tags nothing. Two refusals come first.

   **The tree must contain `main` (or `origin/main`)**, which is QA-04:

   ```text
   release: HEAD does not contain origin/main; merge origin/main, run the full gate on the merge and tag that commit (QA-04)
   ```

   This is not a routine merge and must not be treated as one: v1 is superseded
   wholesale by v2, so the cutover commit is `git merge -s ours origin/main`.
   Its tree stays exactly the v2 tree and its parents record both histories. A
   real merge is not available for this pair: `git merge origin/main` into the
   release candidate produced 139 conflicts, 116 of them under `apps/` (76
   delete/update against the v1 tree that `main` still carries, 45
   both-modified, 18 both-added). That is why the resolution is the documented
   path rather than an exception. The full gate runs on the merged tree, not on
   either parent, and the tag goes on that commit. Record its SHA in the release
   notes next to the coverage baseline date, so the number and the tree it
   describes travel together.

   **The first release needs a baseline.** With no earlier tag, pass
   `--baseline`; without it the tool stops at

   ```text
   release: no baseline tag: create v2.0.0 first (git tag -s v2.0.0), or pass --baseline to cut 2.0.0 as the first release
   ```

   That message is the reference behaviour, and the runbook keeps it rather than
   adding a second path around it.
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
7. Record the CI and Coverage run URLs for the tagged commit next to the tag
   message. The coverage gate has failed at setup before (a cache pin named a
   commit GitHub could not resolve), so the number is not evidence until its run
   URL is recorded. `./task deps-check` now fails on a pin GitHub cannot resolve;
   `./task ci-guards` proves the pin shape.

### What the tag now refuses

`Release: verify tag` runs four checks before any build. Each one fails closed,
and each one is reproducible on a laptop:

| Check | Refuses | Reproduce locally |
|---|---|---|
| `.github/allowed_signers` exists and has a key line | a tag whose signature has no committed trust anchor (SEC-03) | `./task ci-guards --release` |
| `git verify-tag` against that file | a tag signed by a key this repository did not review | `git verify-tag -v v<version>` |
| `git merge-base --is-ancestor origin/main HEAD` | a tag on a tree the gate never ran on (QA-04) | `git merge-base --is-ancestor origin/main HEAD` |
| a completed, successful Coverage run for the commit | a coverage number quoted without its run (QA-15) | the commit's Coverage run on GitHub |

The Coverage run URL that satisfied the last check is written into the release
body under `## Verification`, next to the tagged commit, so the number and the
run travel together. The `deploy-vps.sh` digest scrape is unaffected: the body
still carries exactly one `digest: sha256:…` line and the workflow rejects a tag
message that adds a second digest-shaped string.

Before the first signed release, install `cosign` on the VPS, put the public key
in `/srv/qouver/apps/majadu/env/cosign.pub` (mode 600), and set
`COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` as GitHub Actions secrets. The deploy
refuses to pull a digest it cannot verify.

The one input the repository cannot supply is the signing key itself:
`.github/allowed_signers` holds the public half, and the private key stays with
the owner. That file is the owner's to commit; nobody else can produce it, and
it is not something the pipeline can generate or fake. Until it is committed,
`./task ci-guards --release` fails and so does every tag, which is the intended
state: a release with an unverifiable signature is not a release this
repository can vouch for.

`ops/scripts/release-preflight.sh` still prints
`warn: .github/allowed_signers is not committed; release.yml will verify the tag
through the GitHub API`. That sentence describes the tree before the anchor
lands, when `release.yml` had that fallback. It is true there and false here,
where the workflow refuses the tag outright: read the line as "the anchor is
missing", not as a fallback this pipeline still has.

## 3. What the deploy does

After the cutover gate (`MAJADU_PG_DSN` points at `bm2`) and the version check,
the sequence is:

1. `git fetch origin main` + `git reset --hard origin/main`.
2. Resolve the digest from the GitHub Release, `podman pull` that digest.
3. **`dbtools migrate` + `dbtools seed` + `dbtools verify`** from the newly
   pulled image, using `MAJADU_OWNER_DSN` from `env/majadu-tools.env` (the API
   unit loads only `env/majadu-prod.env` and never sees that credential). A
   failure here = the release is not installed,
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

A release is not done until all eight are true:

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
7. **The load report for the tagged commit is recorded.** `./task loadtest`
   against the release candidate with `--pid` on the API process, with its
   p50/p95/p99, failure count and RSS peak archived in the release evidence
   (T-074). A release without it has no measured capacity, only a configured
   ceiling. `./task loadtest --local` runs the same harness against a database
   it creates and drops, so the report can be produced before the tag instead of
   waiting for a host window; the host run is still the one that exercises the
   512 MB ceiling and the watcher fan-out.
8. **One community per production database, or RLS has already shipped.** The
   first release that serves a second community from one production database
   does not ship until option (a) of `docs/db/rls-tenancy-options.md` is enabled
   on the tenant tables and the two-community isolation test is a gate (ADR-018,
   second Reopener). Nothing in the pipeline checks this: the community count
   lives in the database, so the operator confirms it against the database the
   release will run on.

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
- **Idempotent seeds** (`insert … on conflict do nothing`). The deploy runs
  `dbtools seed` between `migrate` and `verify` on every release, so the config registry in the
  image and the rows in the database cannot drift apart; a seed file that is not
  idempotent turns the next deploy into a failure.
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
## 8. First-release rehearsal

No tag, release, digest or deploy has ever run, so the first execution is the
release. `ops/scripts/release-preflight.sh <tag>` walks the same inputs the
workflow and the deploy read and names the missing one; run it before the tag
and again after the image is published. It creates nothing.

The rehearsal is the release itself, cut from a commit that contains
`origin/main` (§2 step 1, QA-04) with the full gate run on that merged tree,
then rehearsed against the RC database, in this order:

1. `./task release` and `./task release --apply`, then commit
   `chore(release): v<version>`.
2. `git tag -s -F .cache/release/v<version>.md v<version>`, then
   `ops/scripts/release-preflight.sh v<version>`. Fix every `MISSING:` line
   before pushing.
3. `git push origin refs/tags/v<version>` and wait for `release.yml`. Record the
   digest from the release body, then run the preflight again and confirm the
   cosign line.
4. On the VPS, run the deploy by hand against the RC instance first
   (`deploy-vps-rc.sh` builds from the checkout and proves the migrate, seed,
   restart and smoke steps on the same host). Then trigger the production
   deploy and confirm `deploy/last-release.json` carries the digest.
5. Record the run here, with the date, the tag, the digest, the failing step (if
   any) and the commit that fixed it.

| Date | Tag | Digest | Result | Note |
|---|---|---|---|---|
| | | | | |

Until that table has a row, the pipeline is untested and §7 stays true.
