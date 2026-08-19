# Current Status

Last updated: 2026-08-19 (TIER_8_UNIFICATION — 8-tier single source of truth, DEPLOYED dev)

This is the fastest handover file. Start here, lalu baca dokumen terkait di bawah.

## REPO & BRANCH

```
badminton-match (React 19 PWA) ──REST──▶ majadu-api (Go 1.26, net/http+pgx) ──▶ Postgres VPS
  dev  (aktif) · DEPLOYED Vercel        dev  (aktif) · DEPLOYED podman   DB bm_dev (data live)
  main → prod (belum)                   main (lokal, belum push)          DB bm (schema, kosong)
```

## ⭐ TIER 8 UNIFICATION — SELESAI & DEPLOYED (2026-08-19)

- **Single source of truth**: `players.tier` (8: D, D+, C, C+, B, B+, A, A+) —
  tier induk 4 + class rating 12 **digabung**. `rating_players.class/class_source` DROP.
- **Bands** (collapse 12→8, grid 100 dipertahankan): D ≤1199 · D+ 1200-1299 · C 1300-1499 ·
  C+ 1500-1599 · B 1600-1799 · B+ 1800-1899 · A 1900-2099 · A+ ≥2100.
  Forming letter TIDAK berubah (1150/1450/1750/2050) → RebuildAll IDENTIK (0 rating berubah).
- **Floor = basis huruf**: B+ floor B (boleh naik A/A+); A+/A→A, dst. API: `tier`/`tier_derived`/`tier_display`.
- **Generator 8-level** (DEFAULT_TIER 5, weight 2): threshold unevenGames diskala 2→4.
  Trade-off: pool kecil sebaran lebar (8P-2C) pass-rate turun — struktural.
- Migration `000011` applied bm_dev (prod bm belum). Detail: `TIER_8_UNIFICATION.md`.

- Frontend `dev` → `https://api.qouver.com/majadu-dev` · backend dev image `ghcr.io/nferdazel/majadu-api:dev` (auto-update 05:00).
- Branch `staging` SUDAH DIHAPUS (2026-08-18). Supabase pensiun — semua stack Go REST.
- Backend prod: container `majadu-api` (:main, commit 21f4d95) SUDAH deploy di VPS — DB bm kosong.

## Fitur Rating — LENGKAP & DEPLOYED (2026-08-18/22)

**Engine** (RATING_ENGINE_DESIGN.md Rev 3.3):
- Glicko-1-lite: ingest session/classic/team, revert full-rebuild (transitivity), leaderboard/player/history, fingerprint+409/auto_reconcile, advisory lock global, idempotent match_key.
- **Rekalibrasi honest**: rd_growth 3 · initial_rd 220 · max_delta 30 → settled delta 12.8/match (1/8 band), rd mapan 58. Backfill live: 381 events, 98 pemain aktif.

**Tiering** (RATING_TIERING_REVAMP.md Rev 3.7):
- **Tier induk terpusat** (`players.tier` STICKY + `registered_at`): set sekali saat registrasi pertama (nama baru wajib pilih tier), tanpa opsi ubah di session — hanya admin.
- **12 sub-band** (D-..A+, band 100, mid 1150/1450/1750/2050): class/class_derived/class_display di API + badge 12-band; forming = mid kelas (ingest↔rebuild konsisten); floor `{kelas}-` (tidak pernah turun kelas).
- **Season**: `season_start` global, `POST /ratings/season` = close & start (arsip standings beku → hapus events → invalidasi fingerprint → rebuild). Arsip `rating_seasons`+`season_player_snapshots`. Picker musim di UI.

**UI Ratings** (RATINGS_FRONTEND_PLAN.md): `/ratings` leaderboard (class badge, provisional, trend, pagination, season picker live/frozen) + `/ratings/:playerId` (stat cards, sparkline SVG, recent matches, ubah class admin) + cross-link dua arah dengan Player History.

**Admin** (ADMIN_MENU_PLAN.md): card "Admin Area" di grid HomePage → login password (token, persist localStorage) → `/admin` (unlock sesi, ingest/revert/finalize, rebuild, season close&start + arsip, add/delete player standalone, ubah tier induk & class rating). `unlock` di-gate admin.

## Fitur tournament (sesi ini)

Dua format, `tournaments.format` (`classic` | `team`):
1. **Classic**: 16 pasangan → 4 grup → knockout (32 match). Wizard baru (Setup → 16 Pairs → Draw).
2. **Team**: 6 tim × 6 pemain (kelas A+/A/B+/B/C+/C), 3 partai ganda per team-match (C+C, A+A, B+B), rally 30 grup/42 final (no deuce), undian hari-H, top-2 → final (rubber 3 tetap). Poin 3/2/1/0; klasemen poin → W-L diff → poin diff.
- DB: migration 000006 (format column + 4 tabel team). Backend: ValidateTeamTournament + store branch by format. Frontend: TeamWizard + TeamTournamentPage.

## Absent / TBD (ABSENT_TBD_PLAYERS_DESIGN.md — selesai)

- **Void game**: match yang memuat pemain absent/placeholder tidak dihitung siapa pun (standings + career stats + rating). Placeholder (free/tbd/default/dst) tidak diregistrasi; legacy "free*" difilter read-time.
- **Auto-lock**: sesi draft yang tanggalnya lewat otomatis terkunci (ticker 30 mnt) — gate data final + auto-ingest rating.
- Sub hasil change-player masuk leaderboard. Prompt konfirmasi void saat mark absent.

## Redesign UI (selesai)

"Scorekeeper editorial": palet graphite hangat + satu aksen gold, IBM Plex mono, SVG line (zero emoji), zero indigo/violet. Fase 1–5 + audit loop. Backlog: `DESIGN_BACKLOG.md` (gitignored).

## Infra & ops

- Migrations di VPS `/srv/qouver/majadu/migrations/` **000001–000010** (tidak di repo). Apply dev: remap `bm.`→`bm_dev.`; 000003–000005 butuh `PGOPTIONS='-c search_path=bm'`.
- **DB `bm` (prod)**: schema parity bm_dev (24 tabel + rating + season + **migration 000011 tier8 applied** 2026-08-19) — **kosong**. Bedanya hanya kosmetik: urutan kolom & nama 1 FK di `tournament_team_players`.
- Postgres bind `127.0.0.1:5432` — DBeaver WAJIB SSH tunnel (`ssh -L 15432:127.0.0.1:5432 sachiel@43.133.148.191`).
- Log `/srv/qouver/majadu/logs/` · backup 03:00 · auto-update 05:00 · prod container `majadu-api` (Quadlet, `UserNS=keep-id:uid=10001`).
- **Admin token**: di `/srv/qouver/majadu/env/majadu-dev.env` + `majadu-prod.env` (MAJADU_ADMIN_TOKEN — bukan di repo). Login admin = password itu.
- **PR #1 (lumberjack)**: open, dirty, oleh ppabimanyu — analisis diberikan (AdminToken hilang, validate() dibuang, env rename breaking); user copas komentar; belum ada aksi.

## Testing

- Backend `make check` (unit + integration live via tunnel, `MAJADU_TEST_DATABASE_URL` dari .env).
- Frontend `npm run check`: **60 regression** (standings, tournament, teamTournament, sparkline, tiering, placeholders, retry, dll.).
- E2E team flow live PASS. Backfill + season + tiering integration tests PASS live.

## Pending / next

1. **Visual pass browser** (user) — wizard tournament, ratings (leaderboard/class badge/season picker/detail), admin area (login → /admin → unlock/ingest/season/player).
2. **Migrasi prod**: backup Supabase `bm` → restore VPS DB bm → backend `main` (push → CI → auto-update) → frontend `main`.
3. Auth JWT (ditunda). Sticky wizard bottom bar (deferred). Team player career stats (belum aggregate team matches). Port auto-rebase ke dev (backlog).
4. Revert/finalize tetap API-only (token) — tombol admin sudah ada untuk ingest/revert/finalize/season.
5. **Rating engine docs**: RATING_ENGINE_DESIGN (Rev 3.3) · RATING_TIERING_REVAMP (Rev 3.7) · RATINGS_FRONTEND_PLAN · ADMIN_MENU_PLAN · ABSENT_TBD_PLAYERS_DESIGN — semuanya sudah diimplementasi.

## Kunci arsitektur (jangan dilanggar)

- Backend authoritative (validasi/concurrency/identity) · frontend komputasi interaktif (generator/bracket/standings) — "thick client, server authoritative".
- Snapshot-bridge: full snapshot (PUT), server validasi + simpan; zero jsonb di schema app.
- Rating: **honest** (typical win 10–12 = 1/9 band; bukan mainan data) · forming = mid kelas sticky · floor `{kelas}-` · journey dari registered_at · season global.
- Error contract: frontend baca substring pesan backend.

## Dokumen terkait (root badminton-match, semua sudah diimplementasi)

`RATING_ENGINE_DESIGN.md` · `RATING_TIERING_REVAMP.md` · `RATINGS_FRONTEND_PLAN.md` · `ADMIN_MENU_PLAN.md` · `ABSENT_TBD_PLAYERS_DESIGN.md` · `docs/handbook/backend-go-decision.md` · backlog gitignored: `TASK_LIST.md` · `DESIGN_BACKLOG.md` · `TOURNAMENT_BACKLOG.md`.
