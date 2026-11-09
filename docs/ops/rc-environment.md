# Parallel RC environment and the 2.0.0 cutover

Status: **plan approved, RC artifacts already created, execution in stages.**
Date: 2026-11-06.

This document explains three things: how the RC runs without touching
production, what is set up in Vercel and on the VPS, and how merging to `main`
moves the service + database without changing the FE domain.

---

## 1. Goal

| Push | FE | BE | DB |
|---|---|---|---|
| `main` (now) | `majadu.vercel.app` (account `hidaydev`) | `majadu-api` :8080 (v1) | `bm` |
| `release/2.0.0-rc.1` | `majadu-rc.vercel.app` (owner account) | `majadu-rc-api` :8081 | `bm2_rc` |
| after merge | **stays** `majadu.vercel.app` | new production unit on :8080 | `bm2` |

What does not change: the production FE domain and the `/majadu/*` path on
`api.qouver.com`.

---

## 2. Server state (recon 6 Nov 2026)

| Object | Reality |
|---|---|
| `majadu` | production v1, image `localhost/majadu-api:local`, `127.0.0.1:8080`, DB `bm`, role `majadu_app` |
| `majadu2` | a **different** application from the `nferdazel/majadu` repo, port 8093, DB `majadu`, role `majadu2_app` |
| Postgres | container `qouver-postgres`, superuser `qouver`, DB: `bm`, `majadu`, `kran`, `sds`, `fond`, `qouver` |
| `bm2` | **does not exist yet** |
| Host | 2 vCPU, 7.4 GB RAM, 54 GB free disk, podman 5.8.2 |
| `psql` / `pg_dump` | **not installed on the host** |
| sudo | needs a password (no NOPASSWD) |

Two binding consequences:

1. `backup.sh`, `restore.sh`, and `cutover.sh` call `pg_dump`/`psql`
   directly. On this host all three will fail. The RC scripts use containers;
   the production cutover later needs `psql`+`pg_dump` installed or the scripts
   changed.
2. `majadu2` is not a target and must not be touched. All RC names use
   `majadu-rc-*` so they do not collide.

A third consequence comes from the code: one database must not be served by two
versions of the code.
`session.game_results` derives results from `session.game_sets`, while the old
code only writes `session.games.score_a/score_b` and the new code no longer
writes those two columns. That is why moving the DB is a rollback requirement,
not a luxury.

---

## 3. RC topology

| | Production | RC |
|---|---|---|
| FE | `majadu.vercel.app` | `majadu-rc.vercel.app` |
| FE rewrite | `/api/*` → `api.qouver.com/majadu/*` | `/api/*` → `api.qouver.com/majadu-rc/*` |
| Caddy | `handle /majadu/*` → `:8080` | `handle /majadu-rc/*` → `:8081` |
| Unit | `majadu-api` | `majadu-rc-api` |
| App dir | `/srv/qouver/apps/majadu` | `/srv/qouver/apps/majadu-rc` |
| DB | `bm` | `bm2_rc` |
| Deploy | webhook `main` → `deploy-vps.sh` (GHCR digest) | webhook RC → `deploy-vps-rc.sh` (build on the VPS) |
| OIDC redirect | `https://majadu.vercel.app/api/auth/callback` | `https://majadu-rc.vercel.app/api/auth/callback` |

There is no new DNS, no new Postgres, and no new Vercel account beyond the
project itself.

---

## 4. FE: the Vercel RC project

A new project in the owner account, **Git-connected** to `hidaydev/badminton-match`,
so that "push branch → deploy" works without manual steps.

| Setting | Value |
|---|---|
| Project name | `majadu-rc` |
| Production branch | `release/2.0.0-rc.1` |
| Root Directory | `apps/web` |
| Include files outside Root Directory | **on** (pnpm monorepo) |
| Framework preset | Vite |
| Install command | `pnpm install --frozen-lockfile` |
| Build command | `pnpm run build` |
| Output directory | `dist` |
| Node.js version | 22 |
| Environment variables | none; `VITE_API_BASE` is left empty |
| Deployment Protection | **off** |

Prerequisites: the RC branch exists on GitHub, the Vercel account can install
the GitHub App on the `hidaydev` repo, and the RC callback URI is registered in
the Google Cloud Console.

### 4.1 The only RC-specific diff

`apps/web/vercel.json` on the RC branch:

```diff
-{ "source": "/api/:path*", "destination": "https://api.qouver.com/majadu/:path*" },
+{ "source": "/api/:path*", "destination": "https://api.qouver.com/majadu-rc/:path*" },
```

`Content-Security-Policy` does not change because the origin is still
`api.qouver.com`. This line must be reverted to `majadu` before merge. The safety
net: after cutover, `/majadu-rc/*` still points at the same service, so
forgetting the revert does not break production. A tag is stricter: `release.yml`
runs `./task ci-guards --release`, which fails while `apps/web/vercel.json`
contains `majadu-rc`.

---

## 5. BE: the RC instance on the VPS

Artifacts already on the RC branch:

| File | Contents |
|---|---|
| `ops/env/rc.env.example` | RC API env template (DSN `bm2_rc`, RC domain OIDC) |
| `ops/env/rc-tools.env.example` | RC owner DSN for deploy and bootstrap (not loaded by the API unit) |
| `ops/systemd/majadu-rc-api.container` | port `127.0.0.1:8081`, image `localhost/majadu-rc-api:local` |
| `ops/scripts/deploy-vps-rc.sh` | deploy per push to the RC branch |
| `ops/scripts/bootstrap-rc.sh` | one-time: DB + data copy + start |
| `ops/scripts/deploy-dispatch.sh` | ref router for a single GitHub webhook |
| `ops/caddy/site-rc.caddy` | handler `/majadu-rc/*` → `:8081` |

### 5.1 `deploy-vps-rc.sh`

- Fail-closed and literal ref guard:
  `if [ "$REF" != "refs/heads/release/2.0.0-rc.1" ]; then exit 0; fi`.
- Its own `flock` (`/srv/qouver/apps/majadu-rc/.deploy.lock`), it does not share
  the production lock.
- `git fetch` + `reset --hard origin/release/2.0.0-rc.1`.
- **Build on the VPS**: `podman build` from the checkout, `:local` → `:prev`
  rotation. No SHA tag, no GHCR, no git tag.
- `dbtools migrate` + `verify` against `bm2_rc`; `seed` once (marker).
- Sync the unit, restart, wait for `/readyz` for 60 seconds, `smoke.sh`, then
  `/version` must report the commit just built.
- Readiness failure → `:prev` becomes `:local`; the deploy is declared failed.
- Record `version`, `commit`, `schema`, `branch`, `at` in `deploy/last-release.json`.

Why build on the VPS: the RC deploys on every push, while the release path sits
behind a signed tag + `VERSION`. Production still uses the GHCR digest path.

### 5.1.1 The self-install guard and the host residual

`deploy-vps-rc.sh` refreshes its installed copy from the checkout it just
synced, because the webhook runs the installed file. The incoming copy is host
code on the next push, so it is validated first: `bash -n` must pass, the
installed file and its directory must be owned by the deploy user, and the
replace is an atomic rename. A script that fails either check is not installed;
the current run keeps its own inode and the next push starts from a rejected
branch instead of executing it.

That guard is not user separation. The RC deploy and the webhook daemon still
run as the same Unix user that owns `/srv/qouver/apps/majadu`, so a push to the
RC branch can read `majadu-prod.env`, the production podman store and the
`qouver` network. Closing that is a host change, not a repository change:

1. Create a dedicated `majadu-rc` user and a `majadu-rc` group. Make
   `/srv/qouver/apps/majadu` and `/srv/qouver/apps/majadu/env` readable only by
   the production user (`chmod 700` on `env`, the directory is already mode 700
   in the runbook).
2. Move `/srv/qouver/apps/majadu-rc` and `~/.config/systemd/user` for the RC
   units to `majadu-rc`, and run the webhook daemon that invokes the RC script
   as that user (a second daemon, or a per-hook `setuid` wrapper).
3. Install the RC deploy script root-owned (mode 755) rather than letting the
   branch replace its own copy.

Verification, once the user exists:

```sh
sudo -u majadu-rc cat /srv/qouver/apps/majadu/env/majadu-prod.env   # must fail
sudo -u majadu-rc ls /srv/qouver/apps/majadu/env                   # must fail
```

Until those two commands fail, treat the RC as production with a different port.

### 5.2 `bootstrap-rc.sh`
One time only, and it does not touch production:

1. Build the image from the RC branch.
2. Create the `bm2_owner`/`bm2_app` roles + the `bm2_rc` database, migrate, seed.
3. `pg_dump` of `bm` through the container → restore `bm_restore_rc`.
4. `majadu-import etl` + `verify` into `bm2_rc`.
5. Drop the staging database, run `deploy-vps-rc.sh`.

It refuses to overwrite a `bm2_rc` that already has the RC schema; `--force` to
rebuild.

---

## 6. Cutover sequence at merge

Code deploy is automatic; the data move is manual, one command. The reason:
dump/restore must happen when there are no writers, and a failure halfway must
stop with a human in front of the screen.

1. **Freeze `main`** for the cutover window.
2. **Maintenance** for `/majadu/*` (`site-maintenance.caddy`); the v1 service
   stays up.
3. **Copy the data**: dump `bm` → restore `bm_staging` → `majadu-import` into `bm2`
   → `dbtools migrate` + `verify` (this is the contents of `cutover.sh`).
4. **Switch the production env** to the `bm2` DSN and `OIDC_REDIRECT_URI`
   `https://majadu.vercel.app/api/auth/callback`.
5. **Move traffic**: `/majadu/*` → the new production unit.
6. **Smoke**: `/readyz`, `/version`, Google login, one new session, one score,
   one share link, the leaderboard.
7. **Shut down v1**, do not delete: the unit, the `:v1-final` image, and the
   `bm` DB stay.
8. **Merge** `release/2.0.0-rc.1` → `main`, push. The production webhook now
   deploys the same code.
9. **Release**: `VERSION` = `2.0.0`, tag `v2.0.0`, wait for `release.yml`, then
   `./task ranksnapshot` once.

`cutover.sh` already handles steps 2–7 and `rollback.sh` puts v1 back.
What needs fixing before use: the host does not have `psql`/`pg_dump` yet.

---

## 7. Rollback

| Failure point | Action |
|---|---|
| Smoke fails after Caddy is moved | Point `/majadu/*` back to the v1 upstream, reload; v1 is still up and `bm` is untouched |
| `bm2` data is corrupt | Drop `bm2`, repeat from the dump; `bm` is never written |
| After v1 is shut down | `systemctl --user enable --now majadu-api` + Caddy back to v1; `bm2` data written after cutover is lost, so this is a deliberate decision |
| RC is broken | `deploy-vps-rc.sh` already falls back to `:prev` automatically; if needed, run `bootstrap-rc.sh --force` |

---

## 8. Risks

1. **GitHub access in Vercel.** The repo belongs to `hidaydev`; the owner Vercel
   account must be able to install the GitHub App. Alternative: deploy from
   GitHub Actions with `VERCEL_TOKEN`.
2. **One redirect URI per instance.** RC login only works after the RC URI is
   registered in Google. Do not register a random preview domain.
3. **Host without `psql`/`pg_dump`.** Blocks `cutover.sh` as it stands.
4. **VPS load.** The Nim build for every RC push uses 2 vCPU. If it is too
   heavy, move the build to GitHub Actions with an overwritten `rc` tag.
5. **`pnpm check:tailwind` is red** because of two old classes; the RC branch CI
   stays red until they are fixed or the check is loosened.
6. **`main` does not have `VERSION` yet.** It appears after merge; a release tag
   is still mandatory before pushing `main` according to `docs/ops/release.md`.

---

## 9. Decisions

| Question | Answer |
|---|---|
| RC domain | `majadu-rc.vercel.app` |
| Initial `bm2_rc` contents | a production copy through the importer |
| Cutover | one manual command, not automatic from the webhook |
| Who runs the VPS steps | the owner, over SSH from this machine |
| Pushing the RC branch | after the ops artifacts are ready |
| RC DB/service names | `bm2_rc`, `majadu-rc-api`, path `/majadu-rc` |