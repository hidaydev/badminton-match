# Current Status

Last updated: 2026-09-07 (auto-lock void games, rating history null fix)

File handover tercepat. Mulai dari sini, lalu baca dokumen terkait di bawah.

## REPO & BRANCH

```
badminton-match (monorepo)
├── apps/web (React 19 PWA) ──REST──▶ apps/api (Go 1.26, net/http+pgx) ──▶ Postgres VPS
└── main (satu-satunya branch aktif)
```

- **Monorepo**: FE (`apps/web`) + BE (`apps/api`) dalam satu repo `hidaydev/badminton-match` (public).
- **`main`** — satu-satunya branch aktif (production). Branch `dev` & instance dev di-sunset
  (2026-09-04): `bm_dev` di-drop di VPS, `/majadu-dev` tidak lagi di-deploy.
- **Web**: Vercel — Root Directory `apps/web`, auto-deploy dari push `main`.
- **API**: GitHub webhook → build lokal di VPS (`podman build` image `localhost/majadu-api:local`)
  → restart quadlet `majadu-api`. Bukan GHCR.
- API prod: `https://api.qouver.com/majadu` (port 8080, schema `bm`)

## ✅ Baru selesai (2026-08-22 → 2026-09-05)

### Monorepo & deploy (2026-09-04/05)

| Item | Detail |
|------|--------|
| Monorepo consolidation | FE pindah ke `apps/web`; history BE di-import ke `apps/api`; root dirapikan (Makefile, package.json, deploy/, docs/, CI test-only) |
| Sunset dev | `bm_dev` dropped di VPS, instance `majadu-api-dev` berhenti, `dev` branch tidak dipakai |
| Webhook deploy | Gantikan GHCR: push `main` → webhook (HMAC) → `deploy-vps.sh` → build lokal + restart |
| Vercel | Root Directory `apps/web` + Ignored Build Step (pathspec `.`, lihat §deploy) |
| Repo public | Info infra & doc internal di-scrub dari seluruh history |

### Back-to-back marker (`*N` di chip pemain, 2026-09-05)

| Item | Detail |
|------|--------|
| Per-game run marker | Chip hanya bertanda jika game-nya bagian dari run; nilai = panjang run (mis. main 1-2 & 6-7 → `*2` di tiap slot run) |
| Generate + published view | Konsisten di halaman generate (`ScheduleComponents`) dan published summary (`ScheduleGrid`/`PlayerChipRenderer`) |
| Superscript | `*N` kecil terangkat (8px, amber), bukan `*` boolean |

### Auto-lock & ingest: game sengaja tidak dimainkan (2026-09-07)

| Item | Detail |
|------|--------|
| Game "beres" | Game dianggap selesai jika ber-skor ATAU seluruh pemainnya di-skip (⊘ semua) → auto-lock tidak lagi menunggu semua skor terisi (`countDecidedGames` / `allGamesDecided`) |
| Granular skip path | `SetGameSkipped` ikut trigger auto-lock (mirror `SetScore`) — game terakhir diputuskan lewat skip → sesi langsung locked |
| Past-date sweep | Ticker 30 mnt sekarang lock draft yang `session_date`-nya sudah lewat (WIB) sebelum auto-ingest (`LockPastDateDrafts`) — sesi granular-only tidak lagi nongkrong di draft tanpa rating |
| Career stats | Game tanpa skor tidak dihitung di `GamesPlayed` / top partners-opponents (`stats.go`) — konsisten dengan rating engine |

### Rating history: teammates/opponents null (2026-09-07)

| Item | Detail |
|------|--------|
| Bug | Halaman rating player crash `TypeError: can't access property "length", e.teammates is null` — `array_agg` di SQL mengembalikan `NULL` saat teammate/opponent di sebuah game tidak punya baris `rating_deltas` (karena absent/skipped), lalu FE memanggil `.length`/`.join` di atasnya |
| Pre-existing | Terjadi sejak Juli (Bowo, Tari, Fahmi, dll.), baru terlihat setelah session 2026-09-06 ter-ingest |
| Backend | `rating_read.go`: kedua subquery `array_agg` dibungkus `COALESCE(..., '{}')` → selalu emit array, tidak pernah `null` |
| Frontend | `RatingPlayerPage.tsx`: guard defensif `h.teammates ?? []` / `h.opponents ?? []` sebelum `.length`/`.join` |

### SEBELUMNYA (2026-08-22 → 08-30)

1. **PROD MIGRATION (Supabase → VPS)** — bm_dev dibersihkan, migrated.sql (125 players,
   27 sessions), tier overrides, tournament import, rating ingest — semua ✅.
2. **Grand revamp (granular write-path)** — snapshot `PUT` deprecated untuk live ops;
   kontrak live memakai granular (`PATCH /games/{key}`, `PATCH /absent`, swap).
   Lihat `apps/api/README.md` §endpoint & `revamp-grand-plan.md`.
3. **Skip / absent / rating cleanup** — ticker auto-lock dihapus, skip preserves scores,
   `absent_policy` → `skip_player`, rebaseline dihapus, recent matches format
   "with P1 · vs P3, P4", COALESCE NULL tier.
4. **Fitur lain** — 8-tier unified, Glicko-1-lite, team tournament improvements,
   pagination, auto-lock on save, 19 bug fixes, font IBM Plex Sans.

## Infrastruktur

- VPS `user@198.51.100.10` (IP didokumentasikan sebagai placeholder)
- Containers: `majadu-api` (prod:8080), `qouver-postgres` (5432)
- Quadlet configs: `~/.config/containers/systemd/majadu-api.container`
- Deploy: webhook → `deploy/deploy-vps.sh` (bukan GitHub Actions/GHCR)
- Log: `/srv/qouver/apps/majadu/logs/main/app-YYYY-MM-DD.log`
- Migrasi SQL: `000001`–`000011` di VPS (`/srv/qouver/apps/majadu/migrations/`),
  `000012`+ didokumentasikan di [`docs/backend/`](../backend/)

## Database

| Database | Status |
|----------|--------|
| `bm` (prod) | Live — satu-satunya instance (dev `bm_dev` di-drop 2026-09-04) |

Rating config: 22 rows (season_start 2026-05-23, 8-tier ClassBands, absent_policy=skip_player)

## Cara Lanjut

1. Visual pass browser (user)
2. Team tournament share/export
3. E2E testing (opsional — plan lama dihapus dari repo publik; jalankan manual)
4. Rotasi password `qouver` & secret kalau belum
