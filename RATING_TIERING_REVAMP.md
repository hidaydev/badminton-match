# RATING_TIERING_REVAMP.md

**Status:** PLAN — belum diimplementasikan
**Rev:** 3.5 (mekanisme SEASON — season_start global, reset season, forming = baseline musim, recalculate via RebuildAll)
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
- **Prinsip (Rev 3.1): leaderboard harus REAL, REPRESENTATIF, HONEST** — bukan dihidupkan dengan mainan data. Delta per match harus cukup kecil sehingga rating stabil saat skill stabil; hanya bergerak bermakna saat skill benar-benar berubah. Parameter dipilih dari konvensi ELO/Glicko (akurasi), bukan dari keinginan membuat leaderboard "hidup".

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

## 2.5 PRASYARAT — Normalisasi Tier Induk Terpusat (Rev 3.2)

**"Forming" rating membutuhkan tier awal yang DIKETAHUI.** Saat ini tier hanya ada
per-session (`session_players.tier`) — tersebar, tanpa satu sumber kebenaran. Prasyarat:
**normalisasi tier induk (A/B/C/D) ke `bm.players`** yang dikonsumsi oleh ratings engine.

```
SESSION (4 tier, per-session)
   └─► bm.players.tier   ← TIER INDUK TERPUSAT (satu sumber kebenaran)
          └─► RATINGS: kelas awal + rating awal (dikonsumsi saat forming)
```

### 2.5.1 Migration `000009` (SATU file gabungan — lihat juga §4.1) — tambah kolom

```sql
ALTER TABLE bm.players ADD COLUMN tier text;          -- 'A'|'B'|'C'|'D'|NULL — STICKY
ALTER TABLE bm.players ADD COLUMN registered_at date; -- awal journey rating (Rev 3.3)
-- (rating_players.class + class_source tetap seperti §4.1)
```

### 2.5.2 Sinkronisasi dari session — TIER INDUK STICKY (Rev 3.3)

- **STICKY**: `players.tier` ditetapkan SATU KALI saat pemain pertama kali diregistrasi
  (dari tier sesi pertama tempat dia masuk). **TIDAK pernah diubah** oleh sesi berikutnya.
- `players.registered_at` = tanggal registrasi pertama (awal journey) — sticky.
- **TIDAK ADA opsi ubah tier di session lain** (Rev 3.4): nama BARU → host memilih tier
  (itu yang jadi sticky); pemain EXISTING → tier ditampilkan STICKY & LOCKED di UI session
  (PlayersPage tier picker dinonaktifkan). Satu-satunya pintu ubah = **halaman admin**
  (`PATCH /players/{id}/tier`).
- Implementasi: pada session Save, hanya isi kalau `players.tier IS NULL` (first-set).

### 2.5.3 Backfill (satu kali)

- `players.tier` = tier **sesi PERTAMA** per pemain (MIN(session_date), MIN(updated_at)
  tie-break) — konsisten dengan rule sticky (nilai saat "registrasi").
- `players.registered_at` = tanggal sesi pertama tersebut.

### 2.5.4 Dikonsumsi oleh

- **Ratings forming** (inisialisasi kelas + rating awal) — pengganti desain lama
  "baca session_players.tier saat ingest pertama".
- **UI session** (default tier saat add player — referensi konsisten).
- **Admin** ("ubah tier (session)" = edit `players.tier` — lihat ADMIN_MENU_PLAN.md).
- M-DEF/sinkronisasi lain di masa depan.

### 2.5.6 Rule Journey Rating — dimulai SETELAH registrasi (Rev 3.3)

```
perjalanan rating pemain X dimulai dari match pertama dengan date >= X.registered_at
match dengan date <  registered_at  → TIDAK menghitung rating pemain itu
contoh: X diregis 19, match 20 → journey mulai match tgl 20
        X diregis 19, match 19 → journey mulai match tgl 19 (sama hari, ikut)
```

- **Per-match, per-player**: pada ingest, pemain yang `match.date < registered_at`
  tidak ikut dihitung. Jika AKIBATNYA match tidak punya pemain ter-registrasi di kedua
  sisi → match di-skip (mirip void).
- **Forming** (kelas + rating awal) terjadi pada **match pertama yang ter-rated** pemain
  itu (≥ registered_at), memakai tier induk STICKY.
- Ini menjaga kejujuran: riwayat rating = perjalanan sejak didaftarkan, bukan data hantu
  dari match historis sebelum registrasi.

### 2.5.7 Mekanisme SEASON (Rev 3.5)

```
rating_config.season_start (date)  ← GLOBAL, diatur admin (endpoint POST /ratings/season)
   ├─ Ingest: match < max(season_start, players.registered_at) → TIDAK masuk rating
   ├─ RebuildAll: forming tiap pemain di match pertama ≥ season_start
   │    → baseline = mid band KELAS saat itu (bukan 1250 flat)
   └─ RESET SEASON = set season_start (tanggal pilihan admin) → RebuildAll
        → semua pemain balik ke MID KELAS yang di-assign
        → kelas/floor TETAP (identitas lintas musim — "tidak pernah turun kelas" lintas musim)
        → pemain yang tidak main musim baru: rating reset ke mid kelas (konsisten reset-to-default)
```

- **Ubah tier induk → recalculate**: admin update `players.tier`/class → RebuildAll →
  baseline pemain itu berubah (forming ulang), riwayat musim terhitung ulang, efek merambat
  jujur ke lawan.
- **Kelas updated oleh admin** dipakai sebagai baseline reset musim BERIKUTNYA
  ("next season dia tereset ke kelas/tier induk yang sudah diupdate").
- Backfill: `season_start` awal = **2026-05-23** (tournament pertama) — sekali set, admin
  bebas pindah (8 sesi sebelum itu tidak ter-rating).

### 2.5.5 Keputusan yang perlu dikonfirmasi

| Pertanyaan | Usulan |
|---|---|
| Sinkron: sesi terbaru menang? | **TIDAK — STICKY** (set sekali di registrasi; admin-only setelahnya) |
| Player tanpa tier (NULL) | **TIDAK terjadi di alur normal** (Rev 3.4): nama baru wajib pilih tier saat registrasi → `players.tier` selalu terisi. NULL hanya dari edge case: registrasi via API tanpa tier, anomali backfill → fallback initial_rating (tanpa kelas khusus) |
| Edit tier induk via admin → apa efeknya ke ratings? | **Recalculate**: class update → RebuildAll → baseline pemain itu berubah; efek merambat ke lawan (2.5.7) |
| Reset season | Global (`season_start`), semua pemain balik ke mid kelas; kelas tetap (2.5.7) |
| POST /players tier | Tambah param opsional `tier` |
| Player pertama di tournament | registered_at = event_date tournament pertama; fallback C/1250 |

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
- Hubungan poin/match vs band (Rev 3.1 — jujur, bukan mainan): **typical win (pemain mapan) ≈ 10–12 poin = ~1/9 band** · **max_delta cap 25–30 = ≤0.3 band** → 1 match tidak pernah melewati sepertiga band; menang terus ≈ 9–10 match/sub-band; perubahan skill nyata (60% win konsisten) ≈ 1 band per musim.

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

### 4.1 Migration `000009_rating_class.sql` — SATU migration gabungan berisi:
`players.tier` + `players.registered_at` (2.5.1) + `rating_players.class` + `class_source` + seed `rating_config` (`season_start` = 2026-05-23, `session_tier_init`, `class_bands`).

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
| `internal/store/rating.go` (ingest) | Inisialisasi player BARU: `class` + `initial rating` dari **`players.tier` terpusat** (Rev 3.2) — pengganti flat `initial_rating` |
| `internal/store/session.go` (write path) | Sync `players.tier` dari tier session (guard tanggal) |
| Migration `000009` | `players.tier` (sticky) + `registered_at` + `rating_config.season_start` + backfill dari sesi PERTAMA + gate match ≥ max(season_start, registered_at) |
| `internal/store/rating_revert.go` (rebuild) | Reset-to-default: **class & class_source dipertahankan**; hanya rating/rd/peak/games yang direset. **RebuildAll = forming ulang per pemain dari mid kelas di match pertama ≥ season_start** (bukan flat initial) — konsisten dengan ingest; basis mekanisme season & recalculate |
| `internal/handler/ratings.go` | Endpoint `POST /ratings/season {startDate}` (admin) → set season_start + RebuildAll; `POST /players` + param opsional `tier` |
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

### 5.3 Player tanpa tier induk (Rev 3.2)

Player yang `players.tier`-nya **NULL** (belum pernah di sesi — mis. pertama kali muncul di tournament) → fallback: **class = C (tengah sistem), rating = initial_rating (1250)**. Tanpa floor khusus (display = derived murni). Ratings engine membaca `players.tier` (terpusat), bukan `session_players.tier`.

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
- [ ] 0. **Tier induk terpusat (STICKY) + registered_at + season_start**: migration `players.tier`+`registered_at` + `rating_config.season_start`; first-set di session Save (sticky, admin-only); backfill dari sesi PERTAMA (era baseline season_start=2026-05-23); gate match ≥ max(season_start, registered_at) di ingest + integration test (PRASYARAT forming)
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
