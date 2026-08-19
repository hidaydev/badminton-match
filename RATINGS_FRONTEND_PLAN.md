# RATINGS_FRONTEND_PLAN.md

**Status:** PLAN — belum diimplementasikan (docs only)
**Tanggal:** 2026-08-18
**Lokasi:** root badminton-match
**Terkait:** `RATING_ENGINE_DESIGN.md` (backend rating, sudah P0–P3 selesai) · `ABSENT_TBD_PLAYERS_DESIGN.md` (void/placeholder/auto-lock)

---

## 1. Latar & Tujuan

Backend rating engine sudah lengkap (Glicko-1-lite, ingest, revert, leaderboard, player detail/history). Dokumen ini merencanakan **antarmuka frontend** untuk fitur rating:

- **Menu baru "Ratings"** — terpisah dari Player History (analisis §3).
- **Auto-ingest** — rating mengalir otomatis dari lifecycle sesi (auto-lock → ingest), tanpa tombol admin di UI.
- **Cross-link** — Player History ↔ Rating Detail saling menunjuk (pemain yang sama).
- **Tanpa dependency baru** — SVG manual untuk sparkline, ikon/reuse token existing.

---

## 2. Keputusan Desain (sudah disepakati)

| # | Keputusan | Nilai |
|---|---|---|
| 1 | Nama menu | **"Ratings"** (deskripsi: "Skill rating & leaderboard") |
| 2 | Menu terpisah dari Player History | Ya (analisis §3) |
| 3 | Ingest | **Auto-ingest** oleh ticker backend (sesi yang baru auto-lock langsung diingest) — tanpa tombol UI |
| 4 | Revert / Finalize | **API-only** (MAJADU_ADMIN_TOKEN, via curl) — UI menyusul hanya jika benar-benar dibutuhkan |
| 5 | Sparkline | **SVG manual** — tanpa library baru |
| 6 | Ikon card | Emoji konsisten grid HomePage existing (`📈`) |

---

## 3. Analisis: Menu Baru vs Modifikasi Player History

| Dimensi | Player History (existing) | Ratings (baru) |
|---|---|---|
| Semantik | Rekam pribadi — "saya main apa saja" | Permukaan **kompetitif** — "siapa terbaik" |
| Key data | `name` (`GET /players/{name}/stats`) | `player_id` uuid (`GET /ratings/...`) |
| Pola rute | `/player-history/:name` | `/ratings` + `/ratings/:playerId` |
| Kontrak API | stats career | leaderboard + detail + history |
| Fitur khas | sessions/partners/opponents list | tier band, provisional badge, peak, trend, sparkline |

**Kesimpulan:** semantik, sumber data, dan kontrak berbeda — halaman hibrida menambah kompleksitas tanpa nilai. Menu terpisah, tapi **cross-link wajib** karena keduanya membahas pemain yang sama.

---

## 4. Penambahan Backend (prasyarat P0)

### 4.1 `player_id` di leaderboard
`GET /ratings/leaderboard` rows saat ini: `{name, rating, rd, tier, peak, games, trend, provisional}` — **tidak ada uuid**, padahal navigasi ke detail butuh `player_id`. Tambah:

```json
{ "player_id": "uuid", "name": "...", "rating": 1310.0, "rd": 198.8,
  "tier": 4, "peak": 1370.0, "games": 12, "trend": 3.2, "provisional": false }
```

### 4.2 `player_id` di stats response
`GET /players/{name}/stats` saat ini tidak membawa uuid — PlayerDetailPage tidak bisa menautkan ke rating. Tambah `playerId` di root response:

```json
{ "name": "...", "playerId": "uuid", "gamesPlayed": 12, ... }
```

### 4.3 Auto-ingest (ticker backend)
Setelah `AutoLockExpiredSessions` (sudah ada, ticker 30 mnt), tambahkan langkah: **ingest semua sesi yang baru menjadi locked dan belum pernah diingest**.

```
AutoLockPass (ticker 30 mnt):
  1. AutoLockExpiredSessions()          // sudah ada
  2. AutoIngestLockedSessions()         // BARU
     - SELECT share_code FROM sessions s
       WHERE s.status != 'draft'
         AND NOT EXISTS (SELECT 1 FROM rating_sources rs
                         WHERE rs.source_id = s.share_code AND rs.fingerprint != '')
       ORDER BY session_date ASC
     - IngestSession(share_code) per baris (urut kronologis)
```

- Aman & idempotent: `ingest` sudah menangani no-op (fingerprint sama) & out-of-order.
- Log per sesi (processed/skipped) via logger.
- **Tournament tetap manual** (finalize via API) — auto-finalize ditolak (design §4.5).

---

## 5. Kontrak API (yang dipakai frontend)

```
GET /ratings/leaderboard?active=true&limit=100&offset=0
  → { total, rows: [{player_id, name, rating, rd, tier, peak, games, trend, provisional}] }

GET /ratings/players/{playerId}
  → { name, rating, rd, tier, peak, games, wins, losses,
      history: [{date, title, game_ref, outcome, delta, expected, movm, score_a, score_b}] }

GET /players/{name}/stats
  → { name, playerId, gamesPlayed, wins, losses, ... }   // + playerId (baru)
```

Admin (TIDAK dipakai frontend — didokumentasikan untuk curl):
```
POST /ratings/ingest-session      {sessionId}        → {processed, skipped, players}
POST /ratings/ingest-tournament   {tournamentId}
POST /ratings/revert-session      {sessionId}
POST /ratings/revert-tournament   {tournamentId}
POST /ratings/sources/{id}/finalize  {finalized:true}
POST /ratings/rebuild-all
— semua butuh Authorization: Bearer MAJADU_ADMIN_TOKEN
```

---

## 6. Struktur Frontend

### 6.1 Rute (App.tsx)

Konvensi routing dev: halaman di-lazy-load dengan `<Suspense fallback={<Loading />}>`; redirect pola `<Navigate>` bila perlu (pola tournament existing).

```tsx
<Route path="ratings" element={<Suspense fallback={<Loading />}><RatingsPage /></Suspense>} />
<Route path="ratings/:playerId" element={<Suspense fallback={<Loading />}><RatingPlayerPage /></Suspense>} />
```

### 6.2 HomePage card

Grid existing (2 kolom): tambah card `Ratings` (ikon `📈`, label "Ratings", deskripsi "Skill rating & leaderboard") → `navigate('/ratings')`. Posisi: setelah "Player History".

### 6.3 Data layer

`src/queries/endpoints.ts`:
```ts
export interface RatingLeaderboardRow { playerId, name, rating, rd, tier, peak, games, trend, provisional }
export async function getRatingLeaderboard(active: boolean, limit: number, offset: number)
export interface RatingPlayer { name, rating, rd, tier, peak, games, wins, losses, history: RatingHistoryRow[] }
export async function getRatingPlayer(playerId: string)
```

`src/queries/ratings.ts` (react-query hooks):
```ts
useRatingLeaderboard(active, limit, offset)   // queryKey ['ratings', active, offset]
useRatingPlayer(playerId)                     // queryKey ['ratings-player', playerId]
```

`PlayerStats` type + `useGetPlayerStats` response: tambah `playerId?: string` (opsional — aman untuk respons lama; wajib setelah backend P0.2 untuk cross-link).

### 6.4 Encoding cross-link

- Link ke player history **harus encode**: `/player-history/${encodeURIComponent(name)}` — pola `PlayerHistoryPage` existing; `useGetPlayerStats` me-decode (`decodeURIComponent`).
- Link ke rating detail pakai `player_id` (uuid — aman tanpa encoding khusus).

### 6.4 Halaman leaderboard — `/ratings` (`RatingsPage.tsx`)

- Header: "Ratings" + subtitle `n active players · updated via session auto-lock`.
- **Filter toggle**: All / Active (active = games>0 & main ≤ 90 hari — backend `?active=true`).
- **Pagination**: limit 100 per halaman; tombol "Load more" (offset += 100) atau Prev/Next — pilih **Load more** (mobile-friendly).
- **Tabel** (konsisten pola StandingsTab):
  ```
  #   [Tier badge]  Name          Rating   RD      Pk    G    Trend
  1   [B+]          Budi          1490     45.2    1550  24   +3.2
  2   [C+] [prov]   Ani           1275     213.0   1310   6   -1.5
  ```
  - Rank: 1–3 dengan warna podium (gold/silver/bronze — konsisten StandingsTab).
  - `TierBadge` baru (1–10, D..S+) — beda dari TierBadge session (1–4).
  - **Provisional badge**: `rd > 200` → chip `prov` (amber).
  - **Trend**: delta terakhir, hijau `+X` / merah `−X`.
  - Row tap → `/ratings/:playerId`.
- **Empty state**: "No ratings yet — ratings appear automatically once sessions are locked." (+ petunjuk bahwa data lama keingest oleh backfill).
- **Loading/error**: skeleton pulse + pesan error konsisten pola existing.
- Design tokens: `bg-surface`, `border-border-subtle`, `text-fg`, `text-fg-dim`, `bg-elevated`, `accent` (pola halaman tournament dev).

### 6.5 Halaman detail rating — `/ratings/:playerId` (`RatingPlayerPage.tsx`)

- **Header**: name + tier badge + provisional chip + "View player history →" (cross-link `/player-history/:name`).
- **Stat cards** (grid 3–4): Rating (besar) · Peak · Games (W-L) · RD.
- **Sparkline**: SVG polyline rating vs history (urut kronologis — API DESC, dibalik). Tooltip opsional (title attr). Lebar responsif (`viewBox`).
- **Recent matches** (dari `history`): daftar `{date} · {title} · {game_ref} · {outcome W/L} · ±delta` — outcome warna emerald/red, delta hijau/merah.
- **Loading/error/404**: skeleton, error banner, "Player not rated yet".

### 6.6 Sparkline util — `src/utils/sparkline.ts`

```ts
export function ratingSparklinePath(history: { rating: number }[], w: number, h: number): string
// normalisasi [min,max] rating → SVG polyline path; padding; mono numeric.
```
- Murni, tanpa IO — unit-testable.
- Ambil `new_rating` dari history (backend sudah simpan di deltas → expose di history row: tambah `new_rating` di `RatingHistoryRow` backend — kecil).

### 6.7 Cross-link

- **PlayerDetailPage** (`/player-history/:name`): stats response kini punya `playerId` → tombol/link "View rating →" `/ratings/:playerId` (tampil hanya jika `playerId` ada & gamesPlayed > 0).
- **RatingPlayerPage**: link "Player history →" `/player-history/:name` (name dari detail).

---

## 7. UI Component Baru

| Komponen | File | Catatan |
|---|---|---|
| `RatingTierBadge` | `src/components/ratings/RatingTierBadge.tsx` | band D..S+ (1–10), warna dari rating — reuse palet, bukan lib baru |
| `RatingLeaderboardTable` | `src/components/ratings/LeaderboardTable.tsx` | tabel + podium + provisional + trend |
| `RatingSparkline` | `src/components/ratings/RatingSparkline.tsx` | SVG dari util |
| `RatingStatCard` | inline di RatingPlayerPage | kartu stat |

---

## 8. Edge Cases & Keputusan

| Kasus | Keputusan |
|---|---|
| Leaderboard kosong (belum ada sesi locked) | Empty state dengan penjelasan auto-ingest |
| Pemain tanpa rating (uuid valid tapi belum keingest) | 404 "Player not rated yet" → tombol kembali |
| `rd > 200` | Badge `prov` (provisional — rating belum stabil) |
| Trend 0 / kosong | Tampilkan `–` (bukan 0 yang membingungkan) |
| History panjang (> 200) | Backend limit 200; frontend tampilkan semua + "older via player history" catatan |
| Offset melewati total | Load more disabled / tombol hilang |
| Duplicate name (dua pemain beda uuid nama sama) | Rating leaderboard tampil per pemain (uuid); cross-link dari stats menggunakan playerId milik pemain itu — aman |
| Auto-ingest gagal sebagian (satu sesi error) | Ticker lanjut ke sesi berikutnya (log error per sesi) — tidak block |
| Sesi diedit setelah ingest (unlock) | **By design:** auto-ingest TIDAK menyentuh sesi yang diedit (fingerprint ≠ '' → tidak terpilih `NOT EXISTS`) — rating stale sampai revert+re-ingest manual (API); leaderboard menampilkan data terakhir yang valid |

---

## 9. Task List

### P0 — Fondasi API (backend + frontend data layer)
- [ ] 1. Backend: `player_id` di `LeaderboardRow` (+ query) — `rating_read.go`
- [ ] 2. Backend: `playerId` di response stats — `stats.go`/`player.go`
- [ ] 3. Backend: `new_rating` di `RatingHistoryRow` (untuk sparkline)
- [ ] 4. Backend: `AutoIngestLockedSessions` + wire ke ticker (setelah AutoLockExpiredSessions) + integration test
- [ ] 5. Frontend: endpoints (`getRatingLeaderboard`, `getRatingPlayer`) + types (`RatingLeaderboardRow`, `RatingPlayer`, `RatingHistoryRow`)
- [ ] 6. Frontend: hooks (`useRatingLeaderboard`, `useRatingPlayer`) + `playerId?: string` di type stats (opsional)

**Verifikasi P0:** `make check` + integration auto-ingest PASS live · `npm run check` hijau.

### P1 — Leaderboard
- [ ] 7. `RatingTierBadge` (1–10)
- [ ] 8. `RatingsPage` (filter active/all, load more, podium, provisional, trend, empty/loading/error)
- [ ] 9. Rute `/ratings` + card HomePage — **pola Suspense/lazy + redirect (konvensi tournament)**
- [ ] 10. Unit test: tier badge band, trend formatting, empty state logic

**Verifikasi P1:** `npm run check` hijau · browser: data bm_dev live (106 pemain aktif).

### P2 — Detail & cross-link
- [ ] 11. `sparkline.ts` + `RatingSparkline` + unit test (path SVG deterministik)
- [ ] 12. `RatingPlayerPage` (header, stat cards, sparkline, recent matches)
- [ ] 13. Cross-link: PlayerDetailPage → rating; RatingPlayerPage → player history — **link history pakai `encodeURIComponent(name)`**
- [ ] 14. Rute `/ratings/:playerId`

**Verifikasi P2:** `npm run check` hijau · browser: klik leaderboard → detail → sparkline → cross-link dua arah.

### P3 — Audit & polish
- [ ] 15. Audit konsistensi (design tokens, error handling, aksesibilitas)
- [ ] 16. Visual pass browser (user) — daftar periksa: loading, empty, banyak data, provisional, pagination
- [ ] 17. Update `current-status.md` + doc ini (status)

**Verifikasi P3:** semua checklist; tanpa regresi menu lain.

---

## 10. Di Luar Scope (untuk sekarang)

- Admin UI (ingest/revert/finalize/rebuild) — API-only, didokumentasikan.
- Sinkronisasi ke M-DEF.
- Fitur rating lain (mis. band "promosi/degradasi", perbandingan antar pemain).
