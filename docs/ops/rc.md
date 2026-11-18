# RC instance (legacy)

The RC instance is a standalone copy of the v2 stack: a separate Podman service,
a separate database, and the FE in the owner Vercel account. It is a test
environment now — production has served `bm2` since the v2.0.0 cutover and runs
`v2.0.2`, so nothing here is production guidance; `docs/ops/operations.md` and
`docs/ops/release.md` are.

The original plan and its design rationale are in the git history
(`docs/ops/rc-environment.md`, deleted 2026-11-16).

## 1. What is on the server

| Object | Value |
|---|---|
| App dir | `/srv/qouver/apps/majadu-rc` |
| Checkout | `/srv/qouver/apps/majadu-rc/repo` |
| Unit | `majadu-rc-api.service` (Quadlet `majadu-rc-api.container`) |
| Container | `majadu-rc-api`, `127.0.0.1:8081 -> 8080` |
| Image | `localhost/majadu-rc-api:local` (+ `:prev`) |
| Database | `bm2_rc`, role `bm2_owner` / `bm2_app` |
| Env | `/srv/qouver/apps/majadu-rc/env/majadu-rc.env` for the API, plus `majadu-rc-tools.env` for deploy and bootstrap (both 600, dir 700) |
| Caddy | `import /etc/caddy/site-rc.caddy` |
| Public URL | `https://api.qouver.com/majadu-rc/*` |
| Webhook | hook `majadu-monorepo` → `/srv/qouver/apps/majadu/scripts/deploy-dispatch.sh` |

`deploy-vps-rc.sh` refuses an RC API env that still contains any tool DSN
(`MAJADU_OWNER_DSN`, `MAJADU_ETL_DSN`, `MAJADU_ETL_SOURCE_DSN`,
`MAJADU_CUTOVER_RESTORE_DSN`, `MAJADU_AUDIT_DSN`); those belong in
`majadu-rc-tools.env`, which the unit never loads.

`majadu2` (port 8093, DB `majadu`) is a different application from a different
repo. Do not touch it and do not use it for this RC.

Production, for contrast: `majadu` on `127.0.0.1:8080` serves `bm2` with
`localhost/majadu-api:local` (`:prev` kept for rollback) and the `bm2_*` roles;
v1 and its `bm` database are no longer running, and the v1 image is kept as
`:v1-final` for `rollback.sh`.

## 2. One time only: bootstrap

Prerequisites: `majadu-rc.env` is filled in (app DSN, OIDC, share keys),
`majadu-rc-tools.env` holds the owner DSN, and `bm` is not currently being
written by another process.

```sh
# from the checkout on the server
cd /srv/qouver/apps/majadu-rc/repo
git fetch origin release/2.0.0-rc.1
git reset --hard origin/release/2.0.0-rc.1

# the owner's Google subject, so the admin screen can be used
MAJADU_OWNER_SUB=<sub> ./ops/scripts/bootstrap-rc.sh
```

What the script does:

1. Build the image from the RC branch (`APP_COMMIT` = the commit under test).
2. Create the roles and the `bm2_rc` database, `dbtools migrate` + `seed`.
3. `pg_dump` the production database (through the container, because the host has
   no `pg_dump`), restore into `bm_restore_rc`.
4. `majadu-import etl` + `verify` into `bm2_rc`.
5. Create the `deploy/seeded` marker, drop the staging database.
6. Run `deploy-vps-rc.sh` to install the unit and start the service.

The script refuses to overwrite a `bm2_rc` that already contains the RC schema.
To rebuild with the latest production data: `./ops/scripts/bootstrap-rc.sh --force`.

## 3. Caddy (needs sudo)

One time only. The snippet must be readable by the `caddy` user, so it is copied
to `/etc/caddy` (not from the app dir, which is mode 700):

```sh
sudo install -o root -g root -m 644 ops/caddy/site-rc.caddy /etc/caddy/site-rc.caddy
```

Inside the `api.qouver.com` site block in `/etc/caddy/Caddyfile`:

```
import /etc/caddy/site-rc.caddy
```

Then:

```sh
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl restart caddy
curl -fsS https://api.qouver.com/majadu-rc/healthz
```

`restart`, not `reload`: this server's Caddyfile sets `admin off` (audit H-5),
so `caddy reload` has no admin endpoint to reach. Validate first; a failed
validation means no restart. A restart drops every site on the server for about
one second.

If the contents of `ops/caddy/site-rc.caddy` change, repeat the `install` step
above; the deploy script does not write to `/etc/caddy`.

## 4. Daily deploy

Push to `release/2.0.0-rc.1` → hook `majadu-monorepo` →
`deploy-dispatch.sh` → `deploy-vps-rc.sh`:

1. The dispatcher picks the target from `ref`: `refs/heads/main` to
   `deploy-vps.sh`, `refs/heads/release/2.0.0-rc.1` to `deploy-vps-rc.sh`,
   any other ref `exit 0`.
2. A literal ref guard in the target script; any other ref `exit 0`.
3. `flock` on `/srv/qouver/apps/majadu-rc/.deploy.lock`.
4. `git fetch` + `reset --hard origin/release/2.0.0-rc.1`.
5. CI gate: the newest `ci.yml` run for the exact commit must be completed
   with success. A queued or in-progress run is polled (20 attempts, 15 seconds
   apart by default, about five minutes) while the deploy lock is held, then the
   deploy fails closed.
6. `:local` → `:prev`, `podman build` the new image.
7. `dbtools migrate` + `verify` against `bm2_rc`.
8. Sync the unit and `majadu-alert@.service` from the repository, restart
   `majadu-rc-api`, wait for `/readyz` for 60 seconds. The RC may share the
   production user manager or have its own host, so the deploy installs the
   alert template either way; `OnFailure` would otherwise be a silent no-op.
9. `smoke.sh` + `/version` must report the commit just built.
10. Readiness failure → `:prev` becomes `:local`, restart, the deploy is declared
    failed.
11. `image prune`; only `:local` and `:prev` remain tagged.

### 4.1 Why there is no second webhook

The `hidaydev/badminton-match` remote does not offer a menu for adding webhooks,
so the repo has only one hook: `majadu-monorepo` to
`http://127.0.0.1:9000/hooks/majadu-monorepo`. That hook does not filter refs;
every push comes in and `deploy-dispatch.sh` chooses the instance. Both target
scripts still check their own ref, so a routing mistake can only skip a deploy,
never run the wrong branch.

The daemon configuration is in `/srv/qouver/config/webhook.json` (owned by
`sachiel`, mode 600); its unit is a user unit (`systemctl --user restart webhook`),
not a system unit. `ops/scripts/install-webhook.sh` applies the routing from the
repository without touching the HMAC secret, and `ops/webhook/webhook.json` is
the template. Reconcile a missed delivery with `majadu-deploy-check.timer`, which
compares the latest release with `deploy/deployed-version` every hour.

Manual, without the webhook:

```sh
/srv/qouver/apps/majadu-rc/scripts/deploy-vps-rc.sh badminton-match refs/heads/release/2.0.0-rc.1
```

Seeing the last state:

```sh
cat /srv/qouver/apps/majadu-rc/deploy/last-release.json
journalctl --user -u majadu-rc-api -n 50 --no-pager
```

### 4.2 CI gate

The host has no Nim toolchain, so `./task ci` cannot run there. `deploy-vps-rc.sh`
asks GitHub instead: it reads the newest run of the `ci.yml` workflow for the
exact commit being deployed and refuses to build unless that run is `completed`
with `success`. Other workflows are ignored on purpose, so a Coverage run or a
bot check cannot stand in for CI and an unrelated cancelled run cannot block a
healthy commit. A run that is queued or in progress is polled while the deploy
lock is held (`MAJADU_RC_CI_WAIT_ATTEMPTS`, default 20, and
`MAJADU_RC_CI_WAIT_SECONDS`, default 15, about five minutes), then the deploy
fails closed. The wait budget is deliberately shorter than the lock wait, so a
second push that arrives during a CI wait may be dropped by the lock; re-push it
after the current deploy ends.

The token is read from `/srv/qouver/apps/majadu-rc/env/github-token`:

| Item | Value |
|---|---|
| Path | `/srv/qouver/apps/majadu-rc/env/github-token` |
| Mode | `600` (or `400`); the script refuses anything world or group readable |
| Owner | the deploy user, `sachiel` (the same user the webhook runs as) |
| Scope | fine-grained PAT with `Actions: read` on `hidaydev/badminton-match`, or a classic read-only repo token |

The token is passed to `curl` on stdin as a private config, so no copy is
written to disk and nothing sensitive appears in the process list. Without the
file, every RC deploy fails closed.

CI must run for `release/*`. `.github/workflows/ci.yml` triggers on pushes to
`main` and `release/**`, and on pull requests, so `release/2.0.0-rc.1` is
covered without adding a branch to the workflow.

Emergency bypass: run the deploy by hand with
`MAJADU_RC_SKIP_CI_GATE=1`. It logs a `WARNING`, builds without a CI result, and
records `"ci":"bypassed"` in `last-release.json`. Use it only when CI is broken
and the commit has been verified another way.

### 4.2.1 The build lock

`BM-04`: the build was the one step on this host that could run beside another
app's build. The per-app `.deploy.lock` in this script only serialises deploys of
the same app, and the host rule is one build at a time (2 vCPU), so the RC build
goes through `/srv/qouver/bin/qouver-build-lock <app> -- podman build ...`. The
lock is resolved as `MAJADU_BUILD_LOCK`, then `qouver-build-lock` on `PATH`, then
`/srv/qouver/bin/qouver-build-lock`; the app name is
`MAJADU_RC_LOCK_APP` (default `badminton-match-rc`). Its own wait is 900 s and a
timeout exits 75, which the deploy reports as "another build still holds the
lock" rather than as a compile failure.

A host without the lock fails the deploy instead of building unserialised. The
documented override for a rehearsal host is `MAJADU_RC_ALLOW_UNLOCKED_BUILD=1`,
which logs a `WARNING` before building.

The first deploy after merging a change to `deploy-vps-rc.sh` still runs the
previously installed copy in `/srv/qouver/apps/majadu-rc/scripts/`; the new
version is installed during that run and is used from the next one.

### 4.3 The privilege residual

`deploy-vps-rc.sh` refreshes its installed copy from the checkout it just synced,
because the webhook runs the installed file. The incoming copy is host code on
the next push, so it is validated first: `bash -n` must pass, the installed file
and its directory must be owned by the deploy user, and the replace is an atomic
rename. A script that fails either check is not installed; the current run keeps
its own inode and the next push starts from a rejected branch instead of
executing it.

That guard is not user separation. The RC deploy and the webhook daemon still run
as the same Unix user that owns `/srv/qouver/apps/majadu`, so a push to the RC
branch can read `majadu-prod.env`, the production podman store and the `qouver`
network. Closing that is a host change, not a repository change: a dedicated
`majadu-rc` user and group, `/srv/qouver/apps/majadu-rc` and the RC units moved
to it, the webhook invoking the RC script as that user, and the RC deploy script
installed root-owned (mode 755) instead of replacing itself.

Verification, once the user exists:

```sh
sudo -u majadu-rc cat /srv/qouver/apps/majadu/env/majadu-prod.env   # must fail
sudo -u majadu-rc ls /srv/qouver/apps/majadu/env                   # must fail
```

Until those two commands fail, treat the RC as production with a different port.

## 5. FE in Vercel

The `majadu-rc` project has been created in the `qouver` team (owner Vercel
account) and the following settings have already been applied through the API:

| Setting | Value |
|---|---|
| Root Directory | `apps/web` |
| Framework | Vite |
| Install Command | `pnpm install --frozen-lockfile` |
| Build Command | `pnpm run build` |
| Output Directory | `dist` |
| Node.js | 22.x |

What is missing and **no longer mandatory**: the Git connection. There are two
paths, and the active one is the first.

### 5.1 Deploy through a token (active)

`deploy-vps-rc.sh` builds the SPA on the VPS and then sends it to the project:

```sh
# from the repository root: the project's root directory is apps/web and the
# CLI resolves it relative to the working directory.
vercel link --yes --scope qouver --project majadu-rc --token "$(cat env/vercel-token)"
vercel pull --yes --environment=production --token ...
vercel build --prod --token ...
vercel deploy --prebuilt --prod --yes --token ...
```

The token is stored in `/srv/qouver/apps/majadu-rc/env/vercel-token` (mode 600)
and is used only for this project. Without that file, the web step is skipped and
the API still deploys, so adding or revoking the token does not change the API
path.

The installed token comes from the owner's CLI session (`vca_…`). `vercel tokens
create` is refused for this login (`Cannot create tokens for this app`), so if you
want a separate token: create it in the Vercel dashboard → Account Settings →
Tokens, then overwrite the file above. Nothing needs a restart; the next deploy
uses the latest file contents.

### 5.2 Deploy through Git (alternative)

If you later want the standard Vercel pipeline:

1. Install the Vercel GitHub App for the `hidaydev/badminton-match` repo
   (<https://github.com/apps/vercel/installations/new>). The account installing it
   must be able to see that repo, and the Vercel account `nferdazel` must use
   the same GitHub identity.
2. In Vercel: Project `majadu-rc` → Settings → Git → Connect
   `hidaydev/badminton-match`, Production Branch `release/2.0.0-rc.1`.
3. Turn on "Include files outside Root Directory".
4. Delete `env/vercel-token` if you do not want two paths running at once.

Deployment Protection must be off, otherwise the OAuth callback and share links
are blocked.

`apps/web/vercel.json` on the RC tip points `/api` at
`https://api.qouver.com/majadu/*`, the same as `main`. The one deliberate RC diff
(`/majadu-rc/*`) is gone: `./task ci-guards --release` refuses a tag whose tree
still carries it, so the RC front end now talks to the production API path.

Google Cloud Console: add
`https://majadu-rc.vercel.app/api/auth/callback` to Authorized redirect URIs.

If the one that ends up installed is instead `<project>-<team>.vercel.app`, change
`OIDC_REDIRECT_URI` in the RC env and the URI in Google, then restart the unit.

### 5.3 Scoreboard PWA

The courtside scoreboard is a separate Vercel project, `majadu-score`, built
from the repository root (the workspace filter needs the lockfile):

| Item | Value |
|---|---|
| Project | `majadu-score` |
| Root Directory | repository root |
| Install Command | `pnpm install --frozen-lockfile` |
| Build Command | `pnpm --filter majadu-score build` |
| Output Directory | `apps/scoreboard/dist` |
| Domain | `https://majadu-score.vercel.app` (default; a custom domain replaces it) |

`apps/scoreboard/vercel.json` owns the commands, the security headers and the
`no-store` HTML policy; the build fails if it drifts (`check-headers.mjs`). The
app's install, offline and storage expectations live in
`apps/scoreboard/README.md`.
