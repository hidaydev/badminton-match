# tools/rehearsal

Cutover rehearsal harness (T-063). This is **not** part of CI: it needs Podman,
a systemd user session, Caddy, and two rehearsal databases. What runs is the
exact same `ops/scripts/cutover.sh` and `rollback.sh` as production, only
pointed at a sandbox app dir, unit, Caddy site, and databases.

## What it proves

- The 12-step cutover sequence runs on `bm_staging` → `bm2_rehearsal`.
- Quadlet is really used: systemd runs the `majadu-rehearsal` unit.
- Caddy is really used: the sandbox site on `:18081` imports
  `active.caddy`, and `/version` is answered through Caddy, not only through the
  app port.
- `:v1-final` is restored by `rollback.sh` until v1's `/healthz` is green.
- `--from restore-staging` really continues the rest of the sequence after
  `rollback.sh` removes `cutover_state`.
- Duration per step, total, restore, cutover window, and rollback are written to
  `timings.json`.

## What it does not prove

- The production Caddyfile for `api.qouver.com` (the sandbox site is separate;
  `caddy validate` for the production file is still run once on the server, see
  `ops/caddy/Caddyfile.api.qouver.com`).
- DNS, certificates, and Cloudflare.
- Release image builds: the harness uses an already published release digest.
- User comfort during maintenance: that is a scheduling decision, not a test
  result.

## Prerequisites (one time, on the VPS)

1. `bm_staging` contains a copy of the staging database (dump + `restore.sh`).
2. Roles `bm2_owner`, `bm2_app`, `bm2_etl` exist; `ops/db/roles.sql` creates them
   if not.
3. Copy the env templates:

   ```sh
   install -d -m 700 /srv/qouver/apps/majadu-rehearsal/env
   install -m 600 ops/env/rehearsal-v1.env.example \
     /srv/qouver/apps/majadu-rehearsal/env/v1.env
   install -m 600 ops/env/rehearsal-v2.env.example \
     /srv/qouver/apps/majadu-rehearsal/env/v2.env
   ```

   Fill in the real values. The harness rejects files whose mode is not 600 and
   rejects DSNs that point at `bm`, `bm2`, `bm2_dev`, or `postgres`.
4. The release image `localhost/majadu-api:v1-final` exists (from the production
   cutover). If it does not exist yet, the harness uses
   `localhost/majadu-api:local` as v1, which is correct before the first cutover
   and wrong after it.

## Running

```sh
MAJADU_REHEARSAL_ENV_DIR=/srv/qouver/apps/majadu-rehearsal/env \
  tools/rehearsal/rehearse.sh run --version v2.0.0 --dry-run   # see the plan

MAJADU_REHEARSAL_CONFIRM=yes \
MAJADU_REHEARSAL_ENV_DIR=/srv/qouver/apps/majadu-rehearsal/env \
  tools/rehearsal/rehearse.sh run --version v2.0.0             # run it
```

`--dry-run` only prepares the sandbox and prints the commands; it does not touch
systemd, Caddy, or the databases.

`MAJADU_REHEARSAL_DIR` (default `/tmp/majadu-rehearsal`) is the sandbox location.
`MAJADU_REHEARSAL_ADMIN_DSN` (default `postgresql:///postgres`) is used to
create `bm2_rehearsal`.

The result is `tools/rehearsal/timings.json`; commit that file after the
rehearsal. `--no-from-proof` skips the `--from` proof, but the gate then rejects
the result.

## Gate

```sh
./task rehearsal check
```

The gate reads `timings.json` only (no Podman needed), and fails if:

- `status` is not `passed`,
- `--from` is not proven,
- the result is older than 14 days,
- total > 30 minutes, restore > 15 minutes, or cutover window > 10 minutes.

Run this gate before D-day, not after.

## Clean up

```sh
tools/rehearsal/rehearse.sh clean                    # unit, image, sandbox
tools/rehearsal/rehearse.sh clean --drop-databases   # + bm2_rehearsal
```

`bm_staging` is never deleted by the harness; its contents are reused by the
actual cutover.