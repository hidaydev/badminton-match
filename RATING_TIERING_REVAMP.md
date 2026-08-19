# RATING_TIERING_REVAMP.md

**Status:** PLAN — belum diimplementasikan
**Rev:** 3 (band 100 tetap + mid bersih + floor {kelas}- + cap 60 + 3 konsekuensi)
**Tanggal:** 2026-08-18
**Lokasi:** root badminton-match
**Terkait:** `RATING_ENGINE_DESIGN.md` (engine rating) · `RATINGS_FRONTEND_PLAN.md` (UI ratings) · `ADMIN_MENU_PLAN.md` (menu admin)

---

## 1. Latar & Tujuan

- Saat ini: **session** memakai 4 tier (1–4 = A/B/C/D, per-session, tersimpan di `session_players.tier`); **ratings** menurunkan tier 10-band (D..S+) murni dari angka rating.
- Perubahan yang diminta:
  1. **Skema sub-tier 12 band** (D-, D, D+, C-, C, C+, B-, B, B+, A-, A, A+) — **hanya dipakai di menu Ratings**. Tier session tetap 4 (A/B/C/D).
  2. **Player baru** yang diregistrasi saat create session (tier A/B/C/D) → otomatis masuk **sub-tier tengah** hurufnya dengan **rating tengah** band tersebut.
  3. **Mekanisme "tidak pernah turun kelas"**: player yang di-assign kelas C **tidak akan pernah tampil di bawah C-** (floor = sub-tier terendah hurufnya), kecuali diubah manual admin.
- Ini memisahkan dua konsep yang selama ini tercampur: **kelas (assigned, stabil, admin-editable)** vs **band rating (derived dari angka, bergerak)**.

---

## 2. Kondisi Sekarang (fakta terverifikasi)

| Aspek | Nilai |
|---|---|
| Tier session | 1–4 = A/B/C/D (`config/tiers.ts`); tersimpan per-session di `session_players.tier` |
| `bm.players` | Hanya `id, canonical_name, created_at, updated_at` — **TIDAK ada kolom tier/class** |
| Tier di ratings | `domain.TierForRating` — 10-band (D..S+) murni derived dari rating |
| Initial rating | Flat `1250` untuk semua pemain baru (config `initial_rating`) |
| Reset-to-default (rebuild) | Row rating_players direset ke r0/rd0 saat 0 game |

---

## 3. Skema Baru — 12 Sub-Tier (hanya Ratings)

### 3.1 Band boundaries (100 poin per sub-band — tetap & bersih)

```
A+  ≥2100    A   2000–2099   A-  1900–1999
B+  1800–1899 B   1700–1799  B-  1600–1699
C+  1500–1599 C   1400–1499  C-  1300–1399
D+  1200–1299 D   1100–1199  D-  1000–1099
```

- 12 band × 100 = rentang 1000–2200 (muat dalam clamp [1000,2500]).
- **Mid rating (kelas tengah huruf, angka bulat):** D=**1150** · C=**1450** · B=**1750** · A=**2050**.
- Hubungan poin/match vs band: **typical win (pemain mapan) ≈ 1/3 band** · **max_delta cap 60 = 0.6 band** → 1 match TIDAK PERNAH naik 1 band penuh; menang terus ≈ 3 match/sub-band.

### 3.2 Mapping session tier → kelas awal + rating awal

| Session tier | Kelas awal | Rating awal (mid band) |
|---|---|---|
| 1 (A) | A | 2050 |
| 2 (B) | B | 1750 |
| 3 (C) | C | 1450 |
| 4 (D) | D | 1150 |

- RD awal tetap 350 (provisional) — tidak berubah.
- Konfigurabel: `class_bands` + `session_tier_init` di `rating_config` (bukan hardcode).

### 3.3 "Tidak pernah turun kelas" (floor mechanism)

```
floor(kelas) = sub-tier minus huruf itu:  floor(B) = B- · floor(C) = C- · floor(D) = D- · floor(A) = A-
tampil kelas = max( derived_class(rating), floor(kelas) )

contoh: player assigned B, rating turun ke 1200 (band D+) → TAMPIL B- (bukan D)
        player assigned A, rating naik ke 2100 → tampil A+
        player assigned D, rating turun ke 1000 → tampil D-
```

- **Rating ANGKA tidak di-clamp** — hanya display kelas yang di-floor. Glicko tetap bergerak bebas.
- Floor hanya bergerak kalau **admin mengubah kelas** (naik/turun) — "kecuali diubah manual oleh admin".
- A+ tidak punya floor effect (paling atas).

---

### 3.4 Konsekuensi yang disadari (by design)

1. **Awal-by-tier = start tinggi**: player baru tier A masuk di 2050 — di atas pemain terbaik saat ini (data bm_dev max 1896 = B+). Aspirasional: mereka harus "membela" kelas; kalau main jelek rating turun (display tetap di-floor).
2. **Data sekarang 1000–1900** → mayoritas di band D/C; B+ ke atas ~10 pemain; A/A+ zona sepi (khusus pemain exceptional).
3. **Gap display vs rating**: player kelas A yang rating-nya turun ke 1200 tetap tampil A- (floor) — itulah maksud "tidak pernah turun kelas"; rating angka tetap ditampilkan di sampingnya.

---

## 4. Dampak Data Model (migration)

### 4.1 Migration `000009_rating_class.sql`

```sql
-- Kelas assigned per player (12 sub-tier). NULL = belum pernah ter-assign.
ALTER TABLE bm.rating_players ADD COLUMN class text;
ALTER TABLE bm.rating_players ADD CONSTRAINT rating_players_class_ck
  CHECK (class IS NULL OR class IN ('D-','D','D+','C-','C','C+','B-','B','B+','A-','A','A+'));
-- class_source: 'auto' (dari tier session pertama) | 'admin' (diubah manual)
ALTER TABLE bm.rating_players ADD COLUMN class_source text NOT NULL DEFAULT 'auto';
```

### 4.2 Config seed (rating_config)

```sql
('class_bands', '{"A+":[1550,null],"A":[1500,1549],...,"D-":[null,1049]}'),
('session_tier_init', '{"1":{"class":"A","rating":1525},"2":{"class":"B","rating":1375},"3":{"class":"C","rating":1225},"4":{"class":"D","rating":1075}}'),
```

### 4.3 Backfill class untuk pemain existing

Satu kali proses (P2): untuk tiap player aktif di rating_players, ambil tier session PERTAMA kali mereka muncul (`MIN(session_date)` di session_players) → set class + source='auto'. Pemain tanpa riwayat session → NULL.

---

## 5. Dampak Kode

| File (majadu-api) | Perubahan |
|---|---|
| `internal/domain/rating.go` | `TierForRating` → `ClassForRating(rating, config)` 12-band (dari config, bukan hardcode) |
| `internal/domain/rating_config.go` | Tambah `ClassBands map[string][2]*float64` + `SessionTierInit` |
| `internal/store/rating.go` (ingest) | Inisialisasi player BARU: `class` + `initial rating` dari tier session pertama (`session_players.tier` saat match pertama diekstrak) — pengganti flat `initial_rating` |
| `internal/store/rating_revert.go` (rebuild) | Reset-to-default: **class & class_source dipertahankan** (assigned attribute, bukan computed); hanya rating/rd/peak/games yang direset |
| `internal/store/rating_read.go` | Leaderboard/detail: tambah `class` (assigned) + `class_derived` (dari rating) + `class_display` (max) |
| Frontend ratings | `RatingTierBadge` → tampilkan `class_display`; provisional tetap rd>200 |

### 5.1 Mengapa class TIDAK masuk hitungan Glicko

Kelas bukan input matematika engine — Glicko hanya memakai (rating, rd, skor). Kelas = **atribut display/floor**. Ini menjawab pertanyaan kunci: mengubah kelas TIDAK mengubah hasil perhitungan masa lalu (tidak perlu rebuild).

### 5.2 Interplay dengan `initial_rating` (Rev 2 — temuan review)

`initial_rating` (1250) **TETAP dipakai untuk**:
- **Placeholder** (rate_as_unknown): sub tak dikenal = 1250/350 — TIDAK terpengaruh skema kelas.
- **Fallback** player real yang tidak punya tier session (mis. pertama kali muncul di TOURNAMENT — `tournament_*` tidak menyimpan tier, beda dari `session_players.tier`).
- **Reset-to-default** 0-game: rating → **mid kelasnya bila class ada, else initial_rating**. (Keputusan: kelas = identitas → reset ke mid kelas konsisten; fallback 1250.)

Jadi ada DUA sumber inisialisasi: `session_tier_init` (real player dengan tier) vs `initial_rating` (placeholder/fallback/tanpa kelas). Keduanya wajib ada di config — `session_tier_init` bukan pengganti `initial_rating`.

### 5.3 Tournament-first player (Rev 2)

Player yang **pertama kali muncul di tournament** tidak punya tier session → fallback: **class = C (tengah sistem), rating = initial_rating (1250)**. Tanpa floor khusus (display = derived murni). Ditangani di ingest: kalau tidak ada `session_players.tier` untuk player itu → pakai fallback.

---

## 6. Jawaban: "Edit tier player (session) berdampak ke ratings?"

**Analisis:**

| Skenario | Dampak ke ratings? | Mekanisme |
|---|---|---|
| Ubah tier player DI DALAM sesi (biasa, via UI session) | **Tidak langsung** — hanya memengaruhi grouping/generator sesi itu | — |
| Player baru masuk sesi tier X | Ya — menentukan **kelas awal + rating awal** (sekali, saat ingest pertama) | Inisialisasi §5 |
| Admin ubah kelas di menu ratings | Ya — mengubah **floor** (+ opsional rebaseline) | Endpoint baru `PATCH /ratings/players/{id}/class` |
| Ingin "re-baseline" rating ke kelas baru + hitung ulang semua | Ya — **mekanisme sudah ada: `POST /ratings/rebuild-all`** (full rebuild dari events) | RebuildAll |

**Rekomendasi desain: session tier dan ratings class DICOUPLE-KAN HANYA SATU ARAH** (session tier → inisialisasi kelas saat pertama kali). Setelah itu **independen**: kelas hanya berubah oleh admin. Ini menjaga mekanisme "tidak pernah turun kelas" tetap bermakna (kalau setiap edit tier session menyinkronkan kelas, floor jadi tidak stabil).

**Rebaseline** (optional, fase lanjut): aksi admin "set kelas X + rating = mid band X + rebuild" — memakai RebuildAll yang sudah ada.

---

## 7. Edge Cases

| Kasus | Keputusan |
|---|---|
| Player baru tanpa game (0 game) | Tidak punya row rating_players → tidak punya class; muncul saat game pertama |
| Player di backfill (sudah ter-rating) | Class di-backfill dari tier session pertama (P2) |
| Tier session berubah antar sesi (C di sesi 1, B di sesi 2) | Class TETAP dari sesi pertama (tidak sinkron ulang) — "kelas awal" sekali saja |
| Rating turun jauh di bawah floor | Display di-floor (C-); rating angka tetap rendah; naik lagi → kelas ikut naik dari floor |
| Admin naikkan kelas C → A | Floor naik ke A-; display tidak pernah di bawah A- |
| Admin turunkan kelas A → C | Floor TURUN ke C- — satu-satunya cara "turun kelas" (manual admin) |
| Rebuild setelah revert | Class dipertahankan (bukan direset) |
| Duplicate player (dua uuid nama sama) | Class per uuid (per rating_players) — konsisten |
| Player existing sebelum backfill class (class NULL) | Display = derived murni (tanpa floor); backfill P2 mengisi |
| Band 50 poin terlalu sempit? | Kalibrasi P3: jika terlalu bising (player ganti sub-tier tiap game), lebar band diubah via config (tanpa migration) |

---

## 8. Task List

### P0 — Fondasi skema & math
- [ ] 1. Migration `000009_rating_class.sql` (class + class_source + config seed)
- [ ] 2. `domain`: `ClassForRating` 12-band (config-driven) + `floorOf(class)` + `initForSessionTier(tier)` + unit test (semua 12 band, floor, init mapping)
- [ ] 3. `rating_config`: `ClassBands` + `SessionTierInit` (typed + validasi)
- [ ] 4. Integration test: player baru tier C → class C + rating 1225; floor display

**Verifikasi P0:** unit + integration live PASS.

### P1 — Wire ke ingest & read path
- [ ] 5. Ingest: inisialisasi player baru pakai `initForSessionTier` (dari `session_players.tier` match pertama)
- [ ] 6. Rebuild: pertahankan class saat reset-to-default
- [ ] 7. Leaderboard/detail: `class` + `class_derived` + `class_display` di response
- [ ] 8. Frontend: badge tampil `class_display` (RatingTierBadge update)

**Verifikasi P1:** ingest player baru → class/rating benar; rebuild → class tetap; UI render class.

### P2 — Backfill & kalibrasi
- [ ] 9. Backfill class player existing dari tier session pertama (tool/test live bm_dev)
- [ ] 10. Kalibrasi lebar band terhadap data riil (frekuensi ganti sub-tier) → sesuaikan config

**Verifikasi P2:** semua player aktif punya class; distribusi sub-tier wajar.

### P3 — Rebaseline (opsional, admin doc)
- [ ] 11. Endpoint `POST /ratings/players/{id}/rebaseline` — **set `rating_players.rating = mid kelas` LANGSUNG (tanpa rebuild!)**: rebuild akan menimpa rating manual dari events. Ingest berikutnya membaca state saat ini → melanjutkan dari baseline baru secara alami. (Rev 2 — desain awal "set + rebuild" SALAH)

---

## 8.5 Perubahan Kontrak API & Frontend (Rev 2 — BREAKING)

Response leaderboard/detail berubah:
```
SEBELUM: tier: number (1-10, D..S+)
SESUDAH: class: string|null          (assigned, 12-band: "C", "A+", dll)
        class_derived: string        (dari rating, 12-band)
        class_display: string        (max(derived, floor) — yang ditampilkan)
        provisional: bool            (tetap)
```

- Frontend `RatingTierBadge` + `ratingTiers.ts` → **12 band D-..A+** (label string, bukan number).
- `RATINGS_FRONTEND_PLAN.md` response shape ikut di-update.
- Band S/S+ hilang (A+ jadi puncak — sesuai spesifikasi 12-band user).
- Backward compat: tidak ada — API ratings masih baru (belum dipakai produksi), aman diubah.

---

## 9. Di Luar Scope

- Mengubah 4 tier session menjadi 12 — session TETAP 4 tier.
- Sinkronisasi otomatis session-tier → ratings-class setiap sesi.
