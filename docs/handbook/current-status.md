# Current Status

Last updated: 2026-08-19 (penutupan sesi besar: 8-tier · UI/UX polish · audit fix — semua DEPLOYED dev & pushed)

This is the fastest handover file. Start here, lalu baca dokumen terkait di bawah.

## REPO & BRANCH

```
badminton-match (React 19 PWA) ──REST──▶ majadu-api (Go 1.26, net/http+pgx) ──▶ Postgres VPS
  dev  (aktif) · DEPLOYED Vercel        dev  (aktif) · DEPLOYED podman   DB bm_dev (data live)
  main → prod (belum)                   main (lokal, belum push)          DB bm (schema parity, kosong)
```

- Frontend `dev` → Vercel (auto-deploy dari push) · backend dev image
  `ghcr.io/nferdazel/majadu-api:dev` (auto-update 05:00) · API dev: `https://api.qouver.com/majadu-dev`.
- Supabase pensiun (2026-08-15) — semua stack Go REST.

## ✅ Yang SELESAI di sesi ini (2026-08-19)

### 1. 8-TIER UNIFICATION (single source of truth)
- `players.tier` (8: D, D+, C, C+, B, B+, A, A+) = satu-satunya tier.
  `rating_players.class/class_source` DROP (migration `000011`).
- Bands (collapse 12→8, grid 100): D ≤1199 · D+ 1200-1299 · C 1300-1499 · C+ 1500-1599 ·
  B 1600-1799 · B+ 1800-1899 · A 1900-2099 · A+ ≥2100. Forming letter TIDAK berubah
  → RebuildAll IDENTIK (0 rating berubah, terverifikasi).
- Floor = basis huruf (B+ floor B, boleh naik A/A+). API: `tier`/`tier_derived`/`tier_display`.
- Generator 8-level (DEFAULT_TIER 5, weight 2, unevenGames threshold 2→4).
- Migration `000011` applied **bm_dev + bm** (bm kosong). Detail: `DESIGN_ARCHIVE.md` §6.

### 2. UI/UX POLISH
- **Bahasa Inggris** semua string + **skeleton i18n** (`src/i18n/`, typed dict, `t()`/`useT()`, zero deps).
- **Home admin trigger**: card Admin = login/logout (konfirmasi, styling amber) · section
  **ADMIN permanen** (5 card: Unlock Session/Players/Ratings/Tournament/Season) → `/admin?section=X`.
- **AdminPage**: urutan Session→Player→Rating→Tournament→Season · autofocus `?section` ·
  player pagination + search · season meta wrap · baris aksi flex-wrap.
- **Player History diserap** ke `/ratings/:playerId` (section Career) — route `/player-history*`
  DIHAPUS, tanpa cross-link nested.
- **Mobile audit**: flex-wrap di team standings & match detail. Detail: `DESIGN_ARCHIVE.md` §7.

### 3. Backlog & fitur admin
- Backlog: B (stale checkbox), O3 (M-DEF pensiun — repo di-archive), A5 (rename player
  `PATCH /players/{id}/name`), A10 (rebaseline) SELESAI. A11/A12/A13/O6 drop, A6 ditunda.
- Delete session & tournament admin (`POST /sessions/{id}/delete`, `POST /tournaments/{id}/delete` —
  bersihkan rating source + rebuild); feedback Rebuild All inline.
- Fix bug: admin token hilang setelah reload (useEffect sync) · CORS Authorization di preflight ·
  Pager Previous off-by-one.

### 4. Audit (bug fixed)
- `DeletePlayer` + RebuildAll (transitivity — sebelumnya leaderboard diam-diam stale).
- `SetSourceFinalized` source_kind benar utk team tournament (dulu hardcode classic).
- Teks bulk import sesuai default tier (D+).
- Cleanup 16 `rating_sources` yatim `it-*` di bm_dev.
- `go test -race` PASS (tanpa data race) · 0 orphan · 0 tier invalid · 0 events tanpa deltas.

## Fitur stabil (dari sesi sebelumnya — tetap berjalan)

- **Rating engine** (Glicko-1-lite): ingest session/classic/team · revert full-rebuild ·
  fingerprint+409 · auto-reconcile · advisory lock global · idempotent match_key ·
  **rekalibrasi honest** (rd_growth 3 · initial_rd 220 · max_delta 30 → settled delta 12.8/match,
  rd ~58). Backfill live: **381 events, 98 pemain aktif**.
- **Season**: `season_start` global, `POST /ratings/season` = close & start (arsip standings →
  hapus events → invalidasi fingerprint → RebuildAll). `rating_seasons` + `season_player_snapshots`.
- **Tournament**: classic (16 pairs → 4 grup → knockout, wizard Setup→16 Pairs→Draw) & team
  (6 tim × 6 pemain, 3 partai, rally 30/42, undian hari-H, top-2 final).
- **Absent/TBD**: void game (absent/placeholder tidak dihitung siapa pun), placeholder
  pattern-based tidak diregistrasi, auto-lock sesi lewat tanggal (ticker 30 mnt) → gate rating.

## Infra & ops

- Migrations VPS `/srv/qouver/majadu/migrations/` **000001–000011** (tidak di repo).
  Apply dev: remap `bm.`→`bm_dev.`; 000003–000005 butuh `PGOPTIONS='-c search_path=bm'`.
- **DB `bm` (prod)**: schema parity bm_dev (24 tabel, migration 000011 applied) — **kosong**.
  Bedanya kosmetik: urutan kolom & nama 1 FK di `tournament_team_players`.
- Postgres bind `127.0.0.1:5432` — DBeaver WAJIB SSH tunnel
  (`ssh -L 15432:127.0.0.1:5432 sachiel@43.133.148.191`; db `bm_dev`/`bm`, role `majadu_app`,
  password di `majadu-api/.env`).
- Log `/srv/qouver/majadu/logs/` · backup 03:00 · auto-update 05:00 · prod container `majadu-api`.
- **Admin token**: `/srv/qouver/majadu/env/majadu-dev.env` + `majadu-prod.env`
  (MAJADU_ADMIN_TOKEN — tidak di repo).
- **PR #1 (lumberjack)**: open, dirty, oleh ppabimanyu — analisis diberikan; belum ada aksi.

## Testing

- Backend `make check` (unit + integration live via tunnel).
- Frontend `npm run check`: **60 regression** (standings, tournament, team, sparkline,
  tiering 8-band, placeholders, retry, dll.) + `npm run build`.
- `go test -race` PASS. E2E plan siap di `E2E_TESTING_PLAN.md`.

## Pending / next

1. **Visual pass browser (user)** — 8-tier badge/picker, home admin section, `/admin?section=X`,
   ratings Career, mobile.
2. **Migrasi prod**: backup Supabase `bm` → restore VPS DB `bm` → push backend `main`
   (CI → auto-update) → arahkan frontend `main`. (DB bm sudah schema-parity.)
3. Ganti password superuser postgres `qouver` (backlog A2, security).
4. Auth JWT (ditunda) · sticky wizard bottom bar (deferred) · team player career stats
   (belum aggregate team matches) · port auto-rebase ke dev (backlog).
5. Jalankan `E2E_TESTING_PLAN.md` (sweep otomatis backend matrix + Playwright kalau tersedia).

## Kunci arsitektur (jangan dilanggar)

- Backend authoritative (validasi/concurrency/identity) · frontend komputasi interaktif
  (generator/bracket/standings) — "thick client, server authoritative".
- Snapshot-bridge: full snapshot (PUT), server validasi + simpan; zero jsonb di schema app.
- Rating: **honest** (typical win 10–12 ≈ 1/12 band 8-tier) · forming = mid tier sticky ·
  floor = basis huruf · journey dari `registered_at` · season global ·
  `rating_players` ≡ proyeksi(rating_events, players.tier, config) — RebuildAll membuktikannya.
- Error contract: frontend baca substring pesan backend.

## Dokumen terkait

- **Keputusan desain:** `DESIGN_ARCHIVE.md` (rating engine, 8-tier, admin, absent/void, UI/UX)
- `docs/handbook/backend-go-decision.md` · `BACKLOG.md` (backlog hidup) ·
  `E2E_TESTING_PLAN.md` (rencana tes) · `README.md`
