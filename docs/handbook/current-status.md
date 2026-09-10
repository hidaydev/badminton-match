# Current Status

Last updated: 2026-09-10 (fullstack audit fixes, DB performance indexes, SSE catch-up, PWA Workbox offline strategy)

File handover tercepat. Mulai dari sini, lalu baca dokumen terkait di bawah.

## REPO & BRANCH

```
badminton-match (monorepo)
├── apps/web (React 19 PWA, Vite 8, Tailwind v4) ──REST──▶ apps/api (Go 1.26, net/http+pgx) ──▶ Postgres VPS
└── main (satu-satunya branch aktif)
```

- **Monorepo**: FE (`apps/web`) + BE (`apps/api`) dalam satu repo `hidaydev/badminton-match` (public).
- **`main`** — satu-satunya branch aktif (production). Branch `dev` & instance dev di-sunset (2026-09-04).
- **Web**: Vercel — Root Directory `apps/web`, auto-deploy dari push `main` dengan perbandingan git diff `VERCEL_GIT_PREVIOUS_SHA` safe script.
- **API**: GitHub webhook → build lokal di VPS (`podman build` image `localhost/majadu-api:local`) → restart quadlet `majadu-api`.
- **API prod**: `https://api.qouver.com/majadu` (port 8080, schema `bm`).

---

## ✅ Baru selesai (2026-09-10 Audit & Enhancements)

### 1. Fullstack Audit & Security Hardening (10 September 2026)

| Item | Status | Detail |
|------|--------|--------|
| **SSE Single SessionStore Instance** | ✅ `2cd1bd8` | Mengonsolidasikan `SessionStore` di `main.go` agar di-share ke `PlayerHandler`, `TournamentHandler`, dan `RatingsHandler`. Memastikan broadcast event SSE real-time konsisten. |
| **JSON Body Reader Bounded (10MB Limit)** | ✅ `7162255` | Membatasi `json.Decoder` pada semua endpoint mutation backend (`granular.go`, `swap.go`, `player.go`, `ratings.go`) dengan batas maksimum 10MB untuk mencegah DoS/OOM. |
| **DB Error Masking** | ✅ `34126ce` | Melakukan masking error internal database PostgreSQL pada HTTP response di `ratings.go` & `player.go` (`httperr.Wrap`). Detail error mentah tetap aman dicatat di server log via `slog.Error`. |
| **Debounced Publish Queueing** | ✅ `526c905` | Mengurutkan/antrekan mutasi publish di `useDebouncedPublish.ts` jika ada request yang sedang *in-flight* untuk mencegah HTTP 412 *If-Match version conflict* saat input cepat. |
| **Player Deletion Route Guard Fix** | ✅ `ecac032` | Menyinkronkan `session.playerCount` saat menghapus pemain di `playersSlice.ts` agar admin tidak terjebak redirect guard `/session/generate` -> `/session/players`. |
| **Sparkline Flat Line Offset** | ✅ `cb7c8d2` | Memperbaiki kalkulasi Y pada sparkline rating datar (`span === 0`) di `sparkline.ts` agar berada tepat di titik tengah ($y = h / 2$) tanpa nilai `NaN`. |
| **Rate Limiter Eviction & Error Code** | ✅ `21c9a29` | Mengoptimalkan *eviction* rate limiter (`ratelimit.go`) dengan *reservoir/sample eviction* untuk $N \ge 100$ (mencegah stall Mutex), serta menyelaraskan error code ke `"too_many_requests"`. |
| **PGX Pool Lifetime & Read-Only Tx** | ✅ `079b892` | Memasang parameter pool connection DB (`MaxConnLifetime = 30m`, `MaxConnIdleTime = 5m`) di `db.go` serta `AccessMode: ReadOnly` pada read session untuk menghemat 1 network roundtrip. |
| **Rejection Sampling Token Generator** | ✅ `4600907` | Menerapkan *rejection sampling* untuk byte $\ge 248$ di generator `randomAlnum` (`session.go`) untuk menghilangkan bias modulo pada pembuatan session token. |

### 3. Fullstack 13-Bug Systematic Audit & Fixes (10 September 2026 — Commit `e41f274`)

| Item | Status | Detail |
|------|--------|--------|
| **Zustand `migrate` Closure Binding** | ✅ | `createInitialState` mengikat mutator ke live store `(fn) => useStore.setState(fn)` mencegah action terputus saat migration schema LocalStorage. |
| **React Query OCC Version Sync** | ✅ | Instant `setQueryData` pada `onSuccess` `usePublishSession` & `fetchQuery` error recovery untuk mengeliminasi window stale 412 version conflict. |
| **Rating Player History Null Safety** | ✅ | Safe fallback `safeHistory = history ?? []` di `RatingPlayerPage.tsx` mencegah crash saat data history null. |
| **Tournament Bracket Winner Null Check** | ✅ | Validasi `scoreA != null && scoreB != null` di `BracketTab.tsx` mencegah penentuan pemenang prematur pada match unplayed. |
| **Ghost Empty Slots Cleanup** | ✅ | Filter `.filter((m) => m.slots.some((st) => st !== ''))` di `playersSlice.ts` menghapus constraint match yang seluruh slotnya kosong akibat hapus player. |
| **SQL Schema Qualification & Rollback Context** | ✅ | Menambahkan `s.schema` prefix dan `tx.Rollback(context.WithoutCancel(ctx))` di `tournament.go`, `team_tournament.go`, `player.go`, `session.go`, `rating.go`. |
| **Granular Idempotency Fast-Path Cache** | ✅ | Memanggil `setIdempotentResponse` pada `PatchGame`, `PatchGameSkipped`, dan `PatchAbsent` di `granular.go`. |
| **Stale Score & Played Game Reset** | ✅ | Reset `playedGames: []` dan `gameScores: {}` pada mutasi pemain (`playersSlice.ts`), fixed match (`fixMatchesSlice.ts`), dan court config (`sessionSlice.ts`). |
| **Scoreboard Bounds & Parity Validation** | ✅ | Capping skor max 99 dan pengecekan `validateScore(red, blue)` di `ScoreboardPage.tsx` sebelum save. |
| **Team Tournament Optimistic Rollback** | ✅ | Rollback `localMatches` ke snapshot server dan refetch query jika `publishTournament` mutation gagal di `TeamTournamentPage.tsx`. |
| **Cross-Session Cloud Overwrite Guard** | ✅ | `state.cloudSessionId === cloudSessionId` guard di `useDebouncedPublish.ts` mencegah overwrite antar sesi saat perpindahan halaman cepat. |
| **Inconsistent Court Config Cleaning** | ✅ | Reset `schedule: []`, `playedGames: []`, `gameScores: {}` saat `setCourts`, `setSessionStart`, `setSlotMinutes`, `setCourtTime` di `sessionSlice.ts`. |
| **Idempotency Data Race Elimination** | ✅ | Menyimpan serialized JSON `[]byte` dalam `idempotencyStore` di `session.go` mengeliminasi race condition pointer sharing antar-goroutine. |

---

## 🧪 Status Pengujian Penuh (Test Suite)

- **Frontend Unit Tests**: 74/74 tests PASS (`npm run check:web`)
- **Frontend Production Build**: PASS (`npm run build:web`, PWA Service Worker `dist/sw.js` precache)
- **Backend Go Unit Tests**: 183/183 tests PASS (`go test ./...` di `apps/api`)

---

## Infrastruktur

- **VPS Host**: `user@<VPS_IP>`
- **Containers**: `majadu-api` (prod:8080), `qouver-postgres` (5432)
- **Quadlet Config**: `~/.config/containers/systemd/majadu-api.container`
- **Deploy**: GitHub Webhook → `/srv/qouver/apps/majadu/scripts/deploy-vps.sh`
- **Log**: `/srv/qouver/apps/majadu/logs/main/app-YYYY-MM-DD.log`
- **Migrasi SQL**: `000001`–`000011` di VPS, `000012`–`000015` didokumentasikan di [`docs/backend/`](../backend/)

---

## Database

| Database | Status |
|----------|--------|
| `bm` (prod) | Live — satu-satunya instance (dev `bm_dev` di-drop 2026-09-04) |

- Index Tambahan: `idx_rating_players_active`, `idx_rating_deltas_player_event`, `idx_rating_events_sort_lookup`, `idx_session_players_session_player`, `idx_scheduled_games_session`.
- Rating Config: 22 rows (season_start 2026-05-23, 8-tier ClassBands, absent_policy=skip_player).
