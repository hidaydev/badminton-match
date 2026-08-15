# Current Status

Last updated: 2026-08-15 (pasca migrasi backend Go + branch rename)

This is the fastest handover file for continuing work on this repository.

## Branch

- current working branch: `dev` (di-rename dari `ui-revamp` pada 2026-08-15)
- `main` → prod · `dev` → dev · `staging` → dev API (fallback)
- Frontend `dev` ↔ backend Go `dev` (schema `bm_dev`) · `main` ↔ `main` (schema `bm`)

## Arsitektur sekarang (2026-08-15)

```
badminton-match (React 19 PWA) ──REST──▶ majadu-api (Go, net/http + pgx) ──▶ Postgres VPS
```

- **Supabase/PostgREST sudah pensiun** — backend Go (`majadu-api`) satu-satunya backend.
  Keputusan: [`backend-go-decision.md`](backend-go-decision.md).
- **Semua logika bisnis 100% di Go**: write-path session (transaksi + advisory
  lock), read-path session/player (rebuild snapshot, list, stats), tournament
  (write/read + register pemain). Sisa fungsi SQL di DB: `normalize_player_name`
  (dipakai CHECK constraint `player_aliases`), `delete_player`, `set_updated_at`.
- Migrasi DB: `majadu-api/migrations/` 000001–000002 (baseline) → 000003 (write-path
  drop) → 000004 (read-path drop) → 000005 (tournament drop). Semua applied di `bm_dev`.

## Deploy & infrastruktur

| Komponen | Detail |
|---|---|
| Frontend dev | Vercel preview dari branch `dev` (subdomain custom sudah diset) |
| Backend dev | VPS `majadu-api-dev` container, image dari GHCR `:dev`, **auto-update 05:00** (`majadu-auto-update.timer`) |
| Backend prod | Belum aktif — menunggu migrasi prod (phase 7 decision doc) |
| Database | Postgres 18 di container `qouver-postgres`, DB `bm_dev` (dev) / `bm` (prod nanti) |
| Backup | `majadu-backup.timer` harian 03:00 → dump SEMUA db ke `/srv/qouver/backups/postgres/{daily,weekly,monthly}` |
| CI | Backend: `make check` (vet+test+gofmt) di tiap push `dev/main`. Frontend: tanpa CI (di-hapus atas permintaan) |

Deploy manual: `./scripts/deploy.sh dev` (majadu-api repo). Tunnel lokal untuk
integration test: `ssh -f -N -L 15432:127.0.0.1:5432 sachiel@43.133.148.191`.

## Testing

- `make check` (majadu-api): 90+ unit tests + integration env-guarded
  (`MAJADU_TEST_DATABASE_URL`). Integration: round-trip session, write-path
  semantics, **parity read-path** (Go vs SQL — auto-skip setelah drop), **parity
  tournament**, register idempotent.
- `npm run check` (badminton-match): 36 regression tests (node:test) — retry
  policy, generator quality, snapshot helpers, tournament bracket.
- E2E Playwright & supabase smoke: dihapus (2026-08-15).

## Security model

- Endpoint API anonim (auth ditunda — lihat decision doc). Session ID unguessable
  (`crypto/rand`). Mutasi via `If-Match`/version concurrency + advisory lock.
- Rate limit per-IP (token bucket + janitor). Secret hanya di VPS
  (`/srv/qouver/majadu/env/`, mode 600) — tidak pernah di repo/image. Repo public;
  audit 2026-08-15: tidak ada kredensial ter-push (riwayat git dicek).

## What is NOT done yet

1. **Migrasi prod** (phase 7): backup data `bm` dari Supabase → restore ke VPS →
   deploy backend `main` → arahkan frontend `main` (`__API_BASE_URL__` mapping) →
   pensiunkan Supabase.
2. **Auth** (ditunda): JWT/session middleware di Go, alur host tanpa friction untuk pemain.
3. **Menu tournament list** (ditunda): `GET /tournaments` + list page ala sessions.

Docs stale era Supabase sudah dibersihkan 2026-08-15 (archive/, superpowers/,
runbook, audit — dihapus; konteks ada di git history).

## Riwayat singkat

- Era 1: Google Apps Script + Sheets → Era 2: Supabase/PostgREST (`bm`) →
  Era 3: Go backend (majadu-api). Dokumen era lama (archive/, superpowers/,
  runbook, audit) dihapus 2026-08-15 — konteks historis ada di git history
  (`git log --all -- docs/`).
- Migrasi SQL→Go diselesaikan bertahap 2026-08-13 s/d 2026-08-15 (write-path →
  read-path → tournament), tiap fase diverifikasi parity test terhadap DB live.

## If continuing in a new session

1. [`backend-go-decision.md`](backend-go-decision.md) — keputusan arsitektur & fase
2. [`../../TASK_LIST.md`](../../TASK_LIST.md) — backlog (A/B/C done, E/F ditunda)
3. `majadu-api/README.md` — backend: kontrak REST, deploy, DB role
4. [`../design-system.md`](../design-system.md) — tokens & UI patterns
