# Roadmap

Status as of **2026-11-08**. The change history is in git history.

## ✅ Done

- **Backend v2 (Nim 2.4)**: modules `account`, `community`, `player`, `session`,
  `tournament`, `rating`, `achievement`, `share`, `platform`; entrypoint
  `apps/api/src/main.nim`.
- **75-operation contract**: `core.yaml` + `community.yaml` → `api.yaml`,
  `routes_gen.nim`, TS client, fingerprint (`packages/contracts/openapi`).
- **v2 schema**: 48 migrations (`0001`–`0048`), 34 config keys, config and
  achievement seeds.
- **Auth & communities**: OIDC + session cookie, `member`/`host`/`admin` membership,
  invite, join request, settings, append-only audit, platform owner.
- **Sessions**: complete read/write API (schedule, scores, skip, absent, swap, lock/unlock,
  share) with `If-Match` + `Idempotency-Key`; standings computed on the server; host UI
  and the public share page already exist.
- **Points board**: v1 projection from games: 12-week window, best 10 entries
  (one per session/tournament), tier multiplier, tier filter, player detail +
  achievements. `min_sessions` filters the board and thin evidence is only marked.
- **v1 experience on top of the v2 API**: the legacy tree restored in
  `apps/web/src/legacy/`, role-based access (`member`/`host`/`admin`), per-player
  per-game skip, and v1 event medals + rank-streak on the player shelf.
- **Tournaments**: classic (16 pairs, 4 groups, 32 matches) and team (6×6, 9 group matches
  + final, 3 rubbers), FE editor + admin rating ingest.
- **Export**: post/story from a session or tournament, sizes from config.
- **Players**: list, claim/release claim, merge, admin queue.
- **Realtime**: single-use WebSocket ticket, in-memory fan-out (API).
- **Gates**: `check`, `test`, `contract-check`, `coverage`, `parity`, `pnpm
  check:web`, `e2e` (iPhone 17 + POCO F5), CI's 10 push jobs with `gate` last.
- **Ops**: deploy/cutover/rollback/backup/restore/smoke, hardened Quadlet, Caddy
  `/majadu` handler, alert unit, rehearsal harness.
- **Daily snapshot**: `ranksnapshot` ships in the image and is run by
  `majadu-snapshot.timer` (active after cutover); the rank arrow no longer
  depends on a manual snapshot.
- **Release**: SemVer 2.0.0, CHANGELOG, SSH-signed tags, image built once in CI, digest-based
  Release.
- **Go v1 decommission**: source removed; rollback uses `:v1-final`.

## ⏳ Next (outside the 88 tasks)

| # | Item | Why |
|---|---|---|
| 1 | **`platform.outbox` producer** | Realtime is still in-memory → the API must be a single instance. For one VPS this is enough; an outbox only becomes necessary when replicas are added. |
| 2 | **Raise coverage** | The ratchet only holds the line. The Linux baseline (2026-11-09) is the number CI judges: `tools` 80.55%, `modules/player` 88.29%, `modules/session` 90.31%, `shared` 90.38%, `apps/api` 91.34% (`app.nim` is 3,571 lines). |

## 🚧 Operations still open

- **T-063 rehearsal**: harness + gate ready, `timings.json` is still `not_run`;
  needs Podman and a maintenance window on the VPS.
- **VPS evidence** (T-060/061/065): production `caddy validate`, Quadlet parsing,
  digest `podman pull`, stopwatch rollback.
- **T-074 soak**: `ops/scripts/loadtest.mjs` is committed and reports p50/p95/p99 and RSS (`./task loadtest`); the 1 million request + 50 watcher run against the VPS is still outstanding, and `docs/ops/operations.md` records the ceiling as unproven until it is archived.
- **T-082**: remove the `:v1-final` image after 30 days of post-cutover observation.
- **T-108**: force-push of the rewritten history is **postponed** by owner decision;
  a local hook rejects internal audit/review notes coming back in.

## Notes

- Deploy: push `main` → webhook → `ops/scripts/deploy-vps.sh`. While the production env
  still points at `bm`, the script stops before touching the container (cutover gate).
- Backup/restore/cutover/rollback already exist in `ops/scripts/` and are documented
  in [`../ops/cutover.md`](../ops/cutover.md); the procedure has not been executed on the VPS.
- Tests: `./task check` · `./task test` (with `MAJADU_PG_DSN`) · `./task coverage`
  · `./task e2e` · `pnpm check:web`.
