# Current Status

Last updated: 2026-08-22 (kompaksi — setelah redesign + tournament + auto-rebase)

This is the fastest handover file. Start here, lalu baca dokumen terkait di bawah.

## Repo & branch

```
badminton-match (React 19 PWA) ──REST──▶ majadu-api (Go 1.26, net/http+pgx) ──▶ Postgres VPS
  dev  (aktif)                          dev  (aktif)          DB bm_dev (dev)
  main → prod (belum migrasi)            main (lokal, belum di-push)   DB bm (belum)
                                         → push main = trigger CI deploy prod (tahan dulu)
```

- Frontend `dev` → `https://api.qouver.com/majadu-dev` (Vercel) · `main` → `api.qouver.com/majadu`
- **Branch `staging` SUDAH DIHAPUS (2026-08-18)** — dulu sempat di-merge dev→staging, konten jadi identik dev, lalu dihapus lokal+remote karena tak bernilai lagi (stack sudah seragam Go REST, Supabase pensiun). `vite.config.ts` mapping branch: `main`→prod, selain itu (dev/dll)→majadu-dev (fail-closed).
- Backend deploy: push → CI image ghcr → VPS podman (auto-update 05:00 / `./scripts/deploy.sh dev`).

## Fitur Rating (2026-08-18, frontend selesai P0-P3)

- **Menu baru "Ratings"** di HomePage → `/ratings` (leaderboard: tier D..S+, provisional badge, trend, load-more, filter Active/All) + `/ratings/:playerId` (detail: stat cards, sparkline SVG manual, recent matches). **Cross-link dua arah** dengan Player History (playerId kini ada di stats + leaderboard).
- **Backend rating engine sudah live di bm_dev** (P0-P3): Glicko-1-lite, ingest session/classic/team, revert full-rebuild, leaderboard/player/history API. Backfill: 27 source, 474 events, 106 pemain aktif. Kalibrasi: `max_delta_per_game=100` (saturasi 57%→29%), korelasi tier-winrate monotonik.
- **Auto-ingest**: ticker backend (bersama auto-lock 30 mnt) mengingest sesi yang baru terkunci otomatis → rating mengalir tanpa aksi manual. Revert/finalize = API-only (MAJADU_ADMIN_TOKEN).
- Visual pass browser: **belum** (handoff user). Doc: `RATING_ENGINE_DESIGN.md` (Rev 3.1) + `RATINGS_FRONTEND_PLAN.md`.

## Fitur Rating UI + Tiering + Season + Admin (2026-08-18, backend+frontend selesai)

- **Tier induk terpusat** (`players.tier` STICKY + `registered_at`): set sekali saat registrasi pertama (nama baru wajib pilih tier), tanpa opsi ubah di session — hanya admin. Gate rating: match ≥ max(season_start, registered_at).
- **Rekalibrasi honest**: rd_growth 3, initial_rd 220, max_delta 30 → settled delta 12.8/match (1/8 band), rd mapan 58. Backfill live: 381 events, 98 pemain aktif.
- **Tiering 12 sub-band** (D-..A+, band 100, mid 1150/1450/1750/2050): class/class_derived/class_display di API + badge 12-band di UI; forming = mid kelas; floor `{kelas}-` (tidak pernah turun kelas, admin-only ubah).
- **Season**: `season_start` global, `POST /ratings/season` = close & start (arsip standings beku → hapus events → invalidasi fingerprint → rebuild). Arsip: `rating_seasons` + `season_player_snapshots` (migration 000010). Picker musim di UI (live vs frozen).
- **Admin Area**: card di HomePage (segmen amber) → login token → `/admin` (unlock, ingest/revert, rebuild, season, class/tier). `unlock` kini di-gate admin. Backend: PATCH tier/class, DELETE player, POST players tier.
- **Belum deploy** (commit lokal). Visual pass menyusul.

## Fitur tournament (baru, sesi ini)**Dua format, discriminated oleh `tournaments.format` (`classic` | `team`):**

1. **Classic** (existing): 16 pasangan → 4 grup × 4 → 32 match (24 grup + QF/SF/3rd/Final). Tabel relasional existing. **Creation wizard baru**: Tournaments → `+ New` → Classic → Setup → 16 Pairs → Draw → create (POST snapshot valid).
2. **Team** (baru): 6 tim × 6 pemain (kelas A+/A/B+/B/C+/C), tiap team-match 3 partai (C+ C, A+ A, B+ B), rally **30 grup / 42 final** (no deuce, pemenang tepat target), 9 match grup (tiap tim 3×, undian hari-H), **top-2 → final** (partai 3 tetap dimainkan). Poin: 3-0=3 · 2-1=2 · 1-2=1 · 0-3=0. Klasemen: poin → selisih W-L → selisih poin agregat.
   - DB: migration `000006` (VPS `/srv/qouver/majadu/migrations/`) — kolom `format` + tabel `tournament_teams/_team_players/_team_matches/_team_match_games` (player_id di team_players).
   - Backend: `ValidateTeamTournament` (Go), store branch by format (`TeamSave`/`TeamLoad`), handler probe `format`, format-mismatch guard, snapshot emit `format`.
   - Frontend: `utils/teamTournament.ts` (draw/standings/outcome) + `TeamWizard` + `TeamTournamentPage` (tabs Standings/Schedule/Final, Group Draw, skor partai, Create Final).

## Redesign UI (sesi ini, selesai)

- Arah **"scorekeeper editorial"**: palet graphite hangat + **satu aksen gold**, IBM Plex (angka mono), zero emoji-ikon (SVG line), zero indigo/violet, radius `rounded-lg`, header solid + safe-area.
- Fase 1–5 selesai (token, shell, data pages, scoreboard, polish) + audit loop. Backlog: `DESIGN_BACKLOG.md` (gitignored).

## Auto-rebase (branch `staging`, commit `9928ff8`)

- **2 admin update skor beda game tanpa refresh**: di `src/queries/sessions.ts` (staging, stack Supabase RPC) — factory `useSessionRebaseMutation`: saat 409 version mismatch → fetch terbaru → re-apply perubahan lokal → publish ulang (1×). Game SAMA = last-write-wins (disepakati).
- **Belum di-port ke `dev`** (dev pakai factory `useOptimisticMutation` yang beda struktur) — backlog potensial.

## Migrasi data Supabase → bm_dev (selesai)

- Supabase (skema era-2, dump via SQL Editor jsonb_populate_record) → staging `bm_old` → transform → bm_dev. Hasil: 26 sessions, 138 players, 1 tournament classic, dsb. Terverifikasi parity + API.
- Supabase bisa dipensiunkan (data sudah di VPS). PostgREST/GoTrue di VPS sudah dimatikan.

## Infra & ops

- **Migrations SQL TIDAK di repo** — di VPS `/srv/qouver/majadu/migrations/` (000001–000006). Apply dev: remap `bm.` → `bm_dev.`.
- Tunnel integration test: `ssh -f -N -L 15432:127.0.0.1:5432 user@198.51.100.10` (mudah mati — cek `nc -z localhost 15432`).
- Log: `/srv/qouver/majadu/logs/app-YYYY-MM-DD.log` (rotasi harian, retensi 7 hari; `client_ip/bytes`, slow request, slow query tracer, `MAJADU_LOG_LEVEL`).
- Backup Postgres: `majadu-backup.timer` (03:00, semua db) · auto-update backend: `majadu-auto-update.timer` (05:00).
- VPS SSH: `user@198.51.100.10` (key ed25519). Container dev: `majadu-api-dev` (UserNS keep-id).
- **DB `bm` (prod) sudah dibuat + schema lengkap** (2026-08-18): migrations 000001→000006 diaplikasikan berurutan (000003–000005 harus pakai `PGOPTIONS='-c search_path=bm'` karena GRANT-nya tanpa prefix schema). Parity dengan bm_dev: 17 tabel + 3 fungsi identik, ACL schema sama (majadu_app punya USAGE), role qouver/majadu_app/anon/authenticated/service_role siap. Belum ada data (restore dari backup Supabase menyusul).
- **Postgres cuma bind `127.0.0.1:5432`** — DBeaver/client luar WAJIB pakai SSH tunnel (konek langsung ke IP publik → timeout/drop). Tunnel: `ssh -L 15432:127.0.0.1:5432 user@198.51.100.10`.
- **Backend PROD sudah deploy (2026-08-18)**: container `majadu-api` via Quadlet `~/.config/containers/systemd/majadu-api.container` (mirror pola dev) — image `ghcr.io/nferdazel/majadu-api:main` (commit 21f4d95), `Network=qouver`, `UserNS=keep-id:uid=10001` (WAJIB — tanpa ini log init fail: permission denied), port `127.0.0.1:8080` → Caddy `/majadu/*`, env `MAJADU_ENV=prod` + `MAJADU_DB_SCHEMA=bm`, label `AutoUpdate=registry` (ikut auto-update 05:00 bersama dev). Smoke test PASS: healthz/readyz (direct+Caddy), players/sessions/tournaments write-path — data uji sudah dibersihkan (bm kosong).
- **Catatan userns**: container `majadu-api` dibuat manual dengan `--userns=keep-id:uid=10001,gid=10001` juga valid; Quadlet cukup `UserNS=keep-id:uid=10001` (mirror dev). Log init error = tanda mapping userns salah.

## Testing

- Backend `make check`: unit + integration live (env `MAJADU_TEST_DATABASE_URL` dari `.env`).
- Frontend `npm run check`: 49 regression (node:test) — retry, quality, snapshot, tournament, standings, teamTournament.
- E2E team flow live: create → undian → skor → klasemen → final **PASS**.

## Pending / next

1. **Visual pass browser** (user) — wizard classic/team, undian, skor partai, klasemen, final.
2. **Migrasi prod** (fase 7 decision doc): backup `bm` Supabase → restore VPS → backend `main` → frontend `main` → pensiunkan Supabase.
3. **Auth** (ditunda): JWT middleware Go.
4. **Menu tournament list** selesai; opsi merge ke Sessions masih terbuka.
5. **Sticky bottom Back/Next wizard** (4 halaman) — deferred.
6. **Team player career stats** — `get_player_stats` belum aggregate team matches (hanya classic); player_id sudah disimpan.
7. **Port auto-rebase ke dev** (factory `useOptimisticMutation`).
8. **Fitur baru berikutnya** — menunggu definisi.

## Kunci arsitektur (jangan dilanggar)

- Backend authoritative (validasi/concurrency/identity) · frontend komputasi interaktif (generator/bracket/standings) — "thick client, server authoritative".
- Snapshot-bridge: frontend kirim full snapshot (PUT), server validasi + simpan; zero jsonb di schema app.
- Error contract: frontend baca substring pesan backend (`version mismatch`, `unresolved player`, dll.).
- Aturan skor di dua tempat (TS `scoreValidation.ts` ↔ Go `ValidateScore`) — parity test jaga konsisten.

## Dokumen terkait

- Keputusan arsitektur: `docs/handbook/backend-go-decision.md`
- Backlog (gitignored, root): `TASK_LIST.md` · `DESIGN_BACKLOG.md` · `TOURNAMENT_BACKLOG.md`
- Backend: `majadu-api/README.md`
