# TIER_8_UNIFICATION.md — Unifikasi Tier Induk (4) + Ratings (12) → Single 8-Tier

**Status:** PLAN — belum diimplementasikan
**Tanggal:** 2026-08-19
**Tujuan:** menggabungkan **tier induk (4: A/B/C/D)** dan **class rating (12: D-..A+)**
menjadi **satu sistem 8-tier** (`A+, A, B+, B, C+, C, D+, D`) — single source of truth.
**Keputusan user (2026-08-19):** floor = basis huruf · generator 8-level (clean break) ·
migrasi penuh (tanpa arsip) · 4-tier lama tidak valid · host pilih tier dari 8.
**Terkait:** `RATING_TIERING_REVAMP.md` (desain lama — akan disupersede) ·
`RATING_ENGINE_DESIGN.md` · `BACKLOG.md` · `BACKLOG_ANALYSIS.md`

---

## 1. Latar & Masalah

Saat ini ada DUA konsep tier yang tumpang tindih untuk satu pemain:

| Konsep | Kolom | Nilai | Sifat |
|---|---|---|---|
| **Tier induk** | `players.tier` (text) | `A/B/C/D` | sticky, set sekali saat registrasi pertama, admin-only |
| **Class rating** | `rating_players.class` (text) + `class_source` | `D-..A+` (12) | derived + assigned; `class_source` = auto/admin |

Di 12-band ada tiga lapisan: `class` (assigned) · `class_derived` (dari angka rating) ·
`class_display` (max derived vs floor). Ditambah `players.tier` (4) di tabel lain →
total **4 nilai tier berbeda per pemain**. Redundan dan sumber inkonsistensi konseptual.

**Keputusan: unifikasi ke 8-tier** — satu kolom, satu konsep, satu sumber kebenaran.

---

## 2. Keputusan User (final, 2026-08-19)

| # | Keputusan | Detail |
|---|---|---|
| 2.1 | **Floor = basis huruf** | `B+` floor di `B` — tidak boleh tampil di bawah `B`, boleh naik ke `A`/`A+`. Floor: `A+/A→A`, `B+/B→B`, `C+/C→C`, `D+/D→D` |
| 2.2 | **Generator 8-level (clean break)** | Generator memakai 8 level langsung (bukan map ke 4). Perilaku jadwal berubah — WAJIB audit kualitas |
| 2.3 | **Migrasi penuh, tanpa arsip** | `season_player_snapshots.class` (standings beku 12-band) IKUT dimigrasi — tidak ada "arsip format lama" |
| 2.4 | **4-tier lama TIDAK valid** | Semua code path & validasi pindah ke 8-tier. `rating_players.class`/`class_source` dihapus |
| 2.5 | **Host pilih tier dari 8** | Registrasi nama baru → picker 8-tier (sticky setelahnya) |

---

## 3. Desain 8-Tier

### 3.1 Nilai & urutan

```
8-TIER (naik):  D  <  D+  <  C  <  C+  <  B  <  B+  <  A  <  A+
numeric (frontend/generator/session_players.tier): 1 2 3 4 5 6 7 8
```

### 3.2 Band boundaries — COLLAPSE 12→8 (mempertahankan grid 100)

Skema ini dipilih karena **migrasi paling mulus** (lihat §4.3):

```
Tier   Band rating       Forming (mid)      Asal 12-band
──────────────────────────────────────────────────────────
D      ≤1199             1150               D- ∪ D
D+     1200–1299         1250               D+
C      1300–1499         1450               C- ∪ C
C+     1500–1599         1550               C+
B      1600–1799         1750               B- ∪ B
B+     1800–1899         1850               B+
A      1900–2099         2050               A- ∪ A
A+     ≥2100             2150               A+
```

**Alasan pilihan ini (kritis):**
1. Mapping migrasi trivial: minus collapse ke base (`D-→D`, `C-→C`, `B-→B`, `A-→A`); plus tetap.
2. **Derived display pemain existing hampir tidak berubah** — boundary 12-band adalah subset
   boundary 8-band (pemain 1200 tetap D+, 1190 tetap D; hanya ex-`D-`/`C-`/`B-`/`A-` yang kini
   tampil base letter).
3. **Forming letter TIDAK bergeser** (1150/1450/1750/2050 = nilai saat ini) → `RebuildAll`
   setelah migrasi menghasilkan **rating identik dengan sekarang** — tanpa pergeseran skala.
4. Fresh player selalu `derived == assigned` (forming berada di dalam band-nya sendiri).
5. `players.tier` lama (A/B/C/D) = nilai valid 8-tier → **tanpa backfill angka**.

### 3.3 Floor mechanism (keputusan 2.1)

```
floor('A+') = 'A'   floor('A') = 'A'
floor('B+') = 'B'   floor('B') = 'B'
floor('C+') = 'C'   floor('C') = 'C'
floor('D+') = 'D'   floor('D') = 'D'

tier_display = max(tier_derived(rating), floor(players.tier))
```

Contoh (keputusan user): pemain assigned `B+` → floor `B`; rating turun ke zona C → tetap
tampil `B`; rating naik ke zona A → tampil `A`/`A+`.

### 3.4 Forming player baru (`session_tier_init`, 8 entri)

```
tier → { class(=tier), rating awal }
D  → 1150 · D+ → 1250 · C  → 1450 · C+ → 1550
B  → 1750 · B+ → 1850 · A  → 2050 · A+ → 2150
```

- RD awal tetap 220 (initial_rd), clamp rating [1000,2500] tetap.
- Placeholder / fallback tanpa tier → initial_rating (1250), tanpa floor (derived murni).

---

## 4. Dampak Data Model (migration `000011`)

### 4.1 `players.tier` — SATU-SATUNYA sumber kebenaran (text 8-tier)

- Nilai lama `A/B/C/D` sudah valid subset 8-tier → **data tidak perlu diubah**.
- Validasi baru: `tier IN ('A+','A','B+','B','C+','C','D+','D')` (dulu A-D saja).

### 4.2 Kolom yang DIHAPUS

```sql
ALTER TABLE bm.rating_players DROP COLUMN class;        -- tidak ada konsep class lagi
ALTER TABLE bm.rating_players DROP COLUMN class_source;
```

### 4.3 Migration 000011 (satu file gabungan)

```sql
-- 1. Backfill players.tier dari rating_players.class (hanya yang masih NULL —
--    pemain yang ter-registrasi via API/tournament tanpa tier). Mapping 12→8.
UPDATE bm.players p
SET tier = CASE c.class
  WHEN 'D-' THEN 'D'  WHEN 'D' THEN 'D'  WHEN 'D+' THEN 'D+'
  WHEN 'C-' THEN 'C'  WHEN 'C' THEN 'C'  WHEN 'C+' THEN 'C+'
  WHEN 'B-' THEN 'B'  WHEN 'B' THEN 'B'  WHEN 'B+' THEN 'B+'
  WHEN 'A-' THEN 'A'  WHEN 'A' THEN 'A'  WHEN 'A+' THEN 'A+'
END
FROM bm.rating_players c
WHERE p.id = c.player_id AND p.tier IS NULL AND c.class IS NOT NULL;

-- 2. session_players.tier: int 1-4 → int 1-8  (1=A→7, 2=B→5, 3=C→3, 4=D→1)
UPDATE bm.session_players SET tier = CASE tier
  WHEN 1 THEN 7 WHEN 2 THEN 5 WHEN 3 THEN 3 WHEN 4 THEN 1
END WHERE tier BETWEEN 1 AND 4;

-- 3. season_player_snapshots.class: 12→8 (arsip standings beku ikut dimigrasi — keputusan 2.3)
UPDATE bm.season_player_snapshots SET class = CASE class
  WHEN 'D-' THEN 'D' WHEN 'D' THEN 'D' WHEN 'D+' THEN 'D+'
  WHEN 'C-' THEN 'C' WHEN 'C' THEN 'C' WHEN 'C+' THEN 'C+'
  WHEN 'B-' THEN 'B' WHEN 'B' THEN 'B' WHEN 'B+' THEN 'B+'
  WHEN 'A-' THEN 'A' WHEN 'A' THEN 'A' WHEN 'A+' THEN 'A+'
END WHERE class IS NOT NULL;

-- 4. DROP kolom class (setelah backfill selesai)
ALTER TABLE bm.rating_players DROP COLUMN class;
ALTER TABLE bm.rating_players DROP COLUMN class_source;

-- 5. Seed rating_config: class_bands 8 entri + session_tier_init 8 entri
--    (upsert; lihat §3.2 & §3.4 untuk nilainya)
```

> Migration dijalankan di VPS: `bm` (prod) + `bm_dev` (dev). File di
> `/srv/qouver/majadu/migrations/` (tidak di repo).

### 4.4 Setelah migration

- `RebuildAll` (API admin) — forming membaca `players.tier`; hasil identik dengan
  sebelum migrasi (bukti: forming letter tidak berubah). Verifikasi leaderboard sebelum/after.
- `rating_players` tidak lagi menyimpan tier apa pun — hanya rating/rd/peak/games.

---

## 5. Dampak Backend (majadu-api)

| File | Perubahan |
|---|---|
| `internal/domain/rating_config.go` | `ClassBands` 12→8 · `SessionTierInit` 8 entri (key = tier text) · `FloorOf` 8 (basis huruf) · `ValidClass` 8 · `FormingForTier(tier)` = `SessionTierInit[tier]` (tier = class, satu konsep) · `DisplayClass` → `DisplayTier` (max derived vs floor) |
| `internal/store/rating.go` (ingest forming) | Player baru: forming dari `players.tier` (sudah); **hapus** penulisan `rating_players.class` |
| `internal/store/rating_revert.go` (rebuild) | `priorClass` → `priorTier` (baca `players.tier`); reset-to-default: mid dari `players.tier`; tidak menulis class |
| `internal/store/rating_read.go` | Response: `tier` (assigned dari players) · `tier_derived` (8 band) · `tier_display` = max(derived, floor(tier)) — **renaming BREAKING** dari `class*` |
| `internal/handler/ratings.go` | `SetClass` **DIHAPUS** (route + handler) — tidak ada konsep class |
| `internal/store/rating_admin.go` | `SetPlayerTier`: validasi 8 nilai · `SetPlayerClass` dihapus · `RebaselinePlayer`: mid dari config 8 |
| `internal/store/session.go` (`firstSetPlayerTier`) | Mapping snapshot `Player.tier` (int 1-8) → text 8-tier (map 1-8 → text) |
| `internal/handler/player.go` | `SetTier` validasi 8 nilai; `PlayerSummary.TierInduk` = text 8-tier |
| `cmd/server/main.go` | Route `PATCH /ratings/players/{id}/class` dihapus |

### 5.1 Team tournament — gratis

`tournament_team_players.cls` (`A+,A,B+,B,C+,C`) = subset valid 8-tier.
Validasi bisa merujuk `ValidClass` 8 (nilai lama masih valid). Opsional: perluas
team ke 8 kelas nanti (di luar scope revamp ini).

---

## 6. Dampak Generator Schedule (keputusan 2.2 — SUPER HATI-HATI)

### 6.1 Perubahan

| Aspek | Sebelum (4-tier) | Sesudah (8-tier) |
|---|---|---|
| `tierMap` | 1–4 | **1–8** (D=1 … A+=8) |
| `DEFAULT_TIER` (config/generator.ts) | 2 (B) | **5 (B)** — posisi relatif sama (upper-middle) |
| `TIER_DIFF_WEIGHT` | 2 | **2 (awal — audit dulu)** |
| Max `tierDiff` | 6 | **14** (8+8-1-1) |
| Max kontribusi tier | 12 | 28 |

### 6.2 Rencana audit (WAJIB sebelum merge)

1. **Regression**: `quality.test.ts` di-update untuk tierMap 1-8 (unit: qualityScore, isGoodQuality).
2. **Audit empiris**: generate ×100 run untuk konfigurasi kunci (16P-3C, 12P-2C, 24P-3C) →
   ukur playCount spread, back-to-back, repeated pairs, uneven games — bandingkan baseline
   OLD (4-tier) vs NEW (8-tier). Target: tidak ada regresi signifikan di metrik non-tier.
3. **Weight tuning**: jika repeated-pairs/partner-variety memburuk karena tier terlalu dominan
   → turunkan `TIER_DIFF_WEIGHT` ke 1.5 → re-audit. JANGAN langsung asal turun.
4. Keuntungan yang dicari: balance antar pemain lebih halus (B+ vs B kini beda 1 level,
   dulu sama-sama 2).

---

## 7. Dampak Frontend (badminton-match)

| File | Perubahan |
|---|---|
| `src/types/index.ts` | `Tier = 1|2|3|4` → `1|2|3|4|5|6|7|8` (label: 1=D … 8=A+) |
| `src/config/tiers.ts` | `TIER_LABELS/COLORS/BADGE_COLORS/ACTIVE` → 8 entri (1:D, 2:D+, 3:C, 4:C+, 5:B, 6:B+, 7:A, 8:A+). `TIER_NAMES` (Senior/…) → 8 nama atau drop |
| `src/config/ratingTiers.ts` + `RatingTierBadge` | 8 nilai `A+,A,B+,B,C+,C,D+,D` (drop minus) |
| `src/pages/PlayersPage.tsx` | Picker tier 4→8 opsi (nama baru); existing = sticky display (sudah arah ini) |
| `src/pages/AdminPage.tsx` | Picker tier induk 4→8; Rebaseline mid baru |
| `src/generator/index.ts` | tierMap 1-8; `config/generator.ts` DEFAULT_TIER=5 (weight 2 awal) |
| `src/queries/endpoints.ts` + hooks | Response rating: `class*` → `tier*` (leaderboard, player detail, seasons) |
| `src/pages/RatingsPage.tsx` / `RatingPlayerPage.tsx` | Field `tier/tier_derived/tier_display` |

### 7.1 Snapshot contract

- `Player.tier` (CloudSnapshot) = int 1-8. Old published sessions: read-path rebuild
  dari `session_players.tier` (sudah di-migrasi) → aman.
- `PlayerSummary.tierInduk` = text 8-tier (display saja).

### 7.2 Timing deploy

API breaking + UI baru harus rilis bersamaan (backend + frontend). PWA cache lama →
user refresh (standard). Jangan deploy backend sendirian dulu.

---

## 8. Risiko & Mitigasi

| Risiko | Mitigasi |
|---|---|
| **Generator**: jadwal berubah (max tierDiff 14) | §6.2 audit empiris + weight tuning bertahap |
| **API breaking** (`class*` → `tier*`) | Deploy barengan; frontend & backend satu rilis |
| **Forming shift** | Terhindar total (grid 100 dipertahankan, forming letter tetap) |
| **Floor lebih ketat** (B+ floor B, bukan B-) | Disengaja (keputusan 2.1); sosialisasi ke klub |
| **Ex-minus players** tampil base letter | Perilaku baru yang diinginkan (migrasi penuh) |
| **Team tournament** cls | Sudah subset valid — tanpa perubahan wajib |
| **PWA cache** | Deploy + prompt update banner (sudah ada `UpdateBanner`) |

---

## 9. Task List (fase eksekusi)

### Fase 1 — Domain & config (backend)
- [ ] 1. `domain/rating_config.go`: ClassBands 8, SessionTierInit 8, FloorOf (basis huruf),
      ValidClass 8, DisplayTier. Unit test (semua 8 band, floor, forming, fresh-player derived == assigned)
- [ ] 2. `store/rating_config.go` loader + validate (8 entri)

### Fase 2 — Migration 000011 (VPS: bm_dev + bm)
- [ ] 3. SQL: backfill players.tier → map session_players.tier 1-8 → map
      season_player_snapshots.class → DROP class/class_source → seed config 8
- [ ] 4. Apply ke bm_dev; `RebuildAll`; **verifikasi leaderboard sebelum/after IDENTIK**
      (bukti forming letter tidak berubah)

### Fase 3 — Backend write/read path
- [ ] 5. Ingest forming: hapus tulis class; forming baca players.tier
- [ ] 6. `rebuildAll`: priorTier dari players; reset-to-default mid dari players.tier
- [ ] 7. Read path: response `tier`/`tier_derived`/`tier_display`; hapus SetClass
      (handler + route + store); SetPlayerTier validasi 8; firstSetPlayerTier map 1-8→text
- [ ] 8. `make check` + integration live (forming, floor, rebuild identik)

### Fase 4 — Frontend
- [ ] 9. types + config tiers 8 + ratingTiers 8 + badge
- [ ] 10. PlayersPage picker 8; AdminPage picker 8
- [ ] 11. Generator: tierMap 1-8, DEFAULT_TIER 5; quality.test.ts update
- [ ] 12. `npm run check` hijau

### Fase 5 — Audit generator (SUPER HATI-HATI — keputusan 2.2)
- [ ] 13. Audit empiris OLD vs NEW (playcount/b2b/repeated pairs/uneven) ×100 run
- [ ] 14. Weight tuning kalau perlu (2 → 1.5); re-audit
- [ ] 15. Visual pass browser: badge 8-tier, picker, leaderboard, admin

### Fase 6 — Deploy & docs
- [ ] 16. Push backend + frontend bersama (deploy barengan), VPS reload
- [ ] 17. Update docs: `RATING_TIERING_REVAMP.md` (superseded → referensi),
      `RATING_ENGINE_DESIGN.md` (band/floor), `current-status.md`, `BACKLOG.md`
- [ ] 18. Verifikasi live: leaderboard, forming player baru, floor display

---

## 10. Verifikasi Wajib (checklist akseptansi)

1. **Rebuild identik**: leaderboard sebelum vs sesudah migration+rebuild — angka SAMA.
2. **Fresh player**: daftar sebagai `D+` → rating 1250 → derived `D+` (bukan D-/C).
3. **Floor**: pemain `B+` yang ratingnya turun di bawah 1600 tetap tampil `B`, tidak pernah `C`/`C+`.
4. **Naik kelas**: `B+` yang ratingnya ≥1900 tampil `A` (naik natural).
5. **Generator**: 16P-3C & 12P-2C → playCount spread ≤1, b2b ≤ baseline, 0 repeated pairs.
6. **No leftover**: tidak ada referensi `class_source`/`SetClass`/`D-` di kode.
7. **Season**: standings beku musim lama menampilkan 8-tier (sudah dimigrasi).

---

## 11. Referensi

- `RATING_TIERING_REVAMP.md` (Rev 3.7) — desain lama (tier induk + 12-band) — **superseded**
- `RATING_ENGINE_DESIGN.md` (Rev 3.3) — engine rating (Glicko, forming, rebuild)
- `BACKLOG_ANALYSIS.md` — kajian item backlog (konteks A5/A10/dll.)
- `config/generator.ts` · `src/generator/index.ts` — generator schedule
- `internal/domain/rating_config.go` · `internal/store/{rating,rating_revert,rating_read,rating_admin}.go`
- Verifikasi DB: `information_schema` bm_dev (tier text · session_players.tier int · class text)
