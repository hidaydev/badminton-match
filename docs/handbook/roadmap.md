# Roadmap

Status as of **2026-11-26** (Release 2.4.0). The change history is in git history.

## ✅ Done

- **Backend v2 (Nim 2.4)**: modules `account`, `community`, `player`, `session`,
  `tournament`, `rating`, `achievement`, `share`, `platform`; entrypoint
  `apps/api/src/main.nim`.
- **76-operation contract**: `core.yaml` + `community.yaml` → `api.yaml`,
  `routes_gen.nim`, TS client, fingerprint (`packages/contracts/openapi`).
- **v2 schema**: 61 migrations (`0001`–`0061`), 36 config keys, config and
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
  reverse-proxy handler, alert unit, rehearsal harness.
- **Daily snapshot**: `ranksnapshot` ships in the image and is run by
  `majadu-snapshot.timer` (active after cutover); the rank arrow no longer
  depends on a manual snapshot.
- **Release**: SemVer 2.4.0, CHANGELOG, SSH-signed tags, image built once in CI, digest-based
  Release and automated VPS deploy.
- **Go v1 decommission**: source removed; the `:v1-final` rollback tag was lost
  on 2026-11-21, so rollback now fails closed and only `:prev` (v2 → v2) remains
  (ADR-024).

## ⏳ Next (outside the 88 tasks)

| # | Item | Why |
|---|---|---|
| 1 | **`platform.outbox` producer** | Realtime is still in-memory → the API must be a single instance. For one VPS this is enough; an outbox only becomes necessary when replicas are added. |
| 2 | **Raise coverage** | The ratchet only holds the line. The Linux baseline is the number `./task coverage` judges locally; no workflow runs it since `bf84905b`, the per-file floor is what `./task check` gates. Current Linux numbers live in `docs/handbook/current-status.md`, not here. |

## 🚧 Operations still open

- **VPS evidence** (T-060/061/065): captured on qouver1 on 2026-11-26 — production
  `caddy validate` valid, the Quadlet generator reads 13 units, digest
  `sha256:973126e8d7fa` pulls and matches `last-release.json`. The artifact lives
  outside the repo (`2026-11-26-vps-backlog/VPS-EVIDENCE.md`), so the repo carries
  the summary, not the raw output.
- **T-063 rehearsal**: **passed** on qouver1 2026-11-26 (22 s total, 1 s restore,
  15 s window, 7 s rollback, resume proof true), recorded in
  `tools/rehearsal/timings.json`. The rollback half used the `v1-fixture` v1 build,
  because `:v1-final` was already gone.
- **T-074 soak**: **dropped** by owner decision 2026-11-26 (ADR-023). The
  harness stays for the local regression baseline (`./task loadtest --local`);
  no host run is planned, so the capacity ceiling stays unproven and that gap is
  accepted rather than outstanding.
- **T-082**: `:v1-final` was already removed on 2026-11-21 and no `podman save`
  tarball was ever made, so the v1 return path is gone; see ADR-024.
- **REL-BOOT-01**: the Quadlet `After=qouver-postgres.service` units are committed,
  but only one announced host reboot proves them.
- **T-108**: force-push of the rewritten history is **postponed** by owner decision;
  a local hook rejects internal audit/review notes coming back in.

## Notes

- Deploy: push `main` → webhook → `ops/scripts/deploy-vps.sh` with cosign signature verification retry.
- Production runs 2.4.0 on `bm2` at 127.0.0.1:8080 behind Caddy, on PostgreSQL 19.0.
- Tests: `./task check` · `./task test` (with `MAJADU_PG_DSN`) · `./task coverage`
  · `./task e2e` · `pnpm check:web`.
