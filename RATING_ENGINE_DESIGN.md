# RATING_ENGINE_DESIGN.md

**Status:** PROPOSAL — belum diimplementasikan
**Tanggal:** 2026-08-18
**Rev:** 3.1 (review 3 sudut pandang + sinkronisasi absent/TBD + ekstensibilitas + deep review lanjutan: full rebuild, delta cap, RawMatch nama, regex fix)
**Lokasi:** root badminton-match
**Referensi analisis:** M-DEF (`/Users/user/Projects/mdef`) — serap prinsip, BUKAN merge fungsionalitas. Terkait: `ABSENT_TBD_PLAYERS_DESIGN.md` (semantik void/placeholder, auto-lock).

---

## 1. Latar Belakang & Tujuan

M-DEF adalah leaderboard ELO badminton (Flutter + Supabase) dengan "MAJADU Dynamic-Elo Framework". Analisis menyimpulkan model rating-nya bagus secara konsep tetapi rapuh secara pelaksanaan dan kurang fair secara struktural. Dokumen ini mendesain **engine rating baru** untuk ekosistem Majadu (badminton-match + majadu-api) dengan prinsip:

1. **Server-authoritative** — perhitungan di backend Go dalam satu transaksi, bukan di client.
2. **Atomic** — satu batch masuk semua-atau-tidak-sama-sekali; urutan commit = urutan seq.
3. **Idempotent** — re-import/re-run tidak menggandakan efek; edit sumber terdeteksi.
4. **Fair** — uncertainty (RD) menggantikan K-tier; positional pairing untuk format team.
5. **Deterministik** — urutan pemrosesan global dan basis waktu dari data sumber (reproducible).
6. **Auditable** — delta per pemain per match tersimpan permanen; replay = source of truth.

Bukan merge: tidak ada fitur M-DEF yang dipindahkan. Yang diserap hanya *prinsip*: stable match identity, peak ELO, revert terkontrol, tier, decay.

---

## 2. Kelemahan M-DEF → Solusi Desain Ini

| # | Kelemahan M-DEF | Solusi desain |
|---|---|---|
| A | ELO dihitung di client (Dart), DB hanya mirror | Hitung di Go, satu transaksi per batch |
| B | Ordering antar sesi se-date nondeterministik | Ordering key `(date, created_at sumber, source_id, game_order)` |
| C | Team rating = rata-rata (masalah carry / varians) | Positional pairing di format team; RD-aware di classic |
| D | K-tier lifetime (8/12/24) tanpa konsep kepercayaan | Glicko RD (uncertainty) per pemain |
| E | MoVM tidak ternormalisasi terhadap target skor | `m = margin/target`, MoVM di-cap |
| F | Bonus tournament flat +8 tanpa bobot fase | Phase weight configurable |
| G | Decay global per-import (session-triggered) | RD growth berbasis waktu sumber (deterministik) |
| H | Replay peak pakai rating saat ini (perkiraan) | Audit trail lengkap → peak dari history |
| I | Tidak bisa import format team baru | Ingest terpisah per format (branch via `TournamentFormat`) |

---

## 3. Model Matematika — "Glicko-1-lite (Online)"

Variasi Glicko yang berjalan **per match** (tanpa rating period), cocok untuk ingestion batch yang datang tidak teratur (mingguan).

### 3.1 Notasi & Konstanta

```
q      = ln(10) / 400                    ≈ 0.0057565
g(rd)  = 1 / sqrt(1 + 3·q²·rd²/π²)        (pembobot RD lawan)

r0     = 1250   rating awal
rd0    = 350    RD awal (provisional)
rd_min = 30     RD minimum (pemain sangat konsisten)
rd_max = 350    RD maksimum
c      = 15     pertumbuhan RD per hari (kalibrasi §3.6)

clamp rating: [1000, 2500] · clamp RD: [30, 350]
```

### 3.2 Expected Score & Update per Pemain

Pemain `i` (tim A) melawan lawan `j` (tim B, 1–2 pemain; format team: hanya *counterpart langsung*, §3.3):

```
E_j   = 1 / (1 + 10^(−g(rd_j)·(r_i − r_j)/400))      expected vs tiap lawan
S     = 1 (menang) | 0 (kalah) | 0.5 (seri)           (seri tidak terjadi di badminton)
MoVM  = §3.4 (pengali margin) · w = phase_weight (§3.5)

d²    = ( q² · Σ_j g(rd_j)² · E_j·(1−E_j) )⁻¹
r_i'  = r_i + MoVM·w · ( q / (1/rd_i² + 1/d²) ) · Σ_j g(rd_j) · (S − E_j)
rd_i' = sqrt( 1 / (1/rd_i² + 1/d²) )
```

**Keputusan Rev 2 (dikoreksi Rev 3.1):** `MoVM·w` mengalikan **seluruh update** (bukan hanya S) — simetris untuk pemenang & pecundang. Catatan: **Glicko bukan sistem zero-sum** — tiap pemain memakai faktor `q/(1/rd_i²+1/d²)` sendiri (rd & d² berbeda), jadi `+X` pemenang ≠ `−X` pecundang kecuali state identik. Pool dapat bergeser sedikit — perilaku Glicko normal. Alternatif (scale S saja) meng-inflasi sisi pemenang secara asimetris — **ditolak**.

### 3.3 Positional Pairing (team) vs Team-Average (classic)

**Format TEAM** (6 tim × 6 pemain, 3 partai per team-match): setiap partai adalah ganda `X+&X` vs `X+&X` (partai 1 = C+&C, partai 2 = A+&A, partai 3 = B+&B). Expected setiap pemain dihitung hanya terhadap **counterpart langsung**:

```
partai 1: (C+ A vs C+ B) dan (C A vs C B)
partai 2: (A+ A vs A+ B) dan (A A vs A B)
partai 3: (B+ A vs B+ B) dan (B A vs B B)
```

Fairness: pemain A+ tidak diuntungkan partner C+ yang kalah; pemain C+ tidak dihukum karena expected dihitung dari lawan C+ sebenarnya. Partner diabaikan dari expected — dapat dibenarkan karena pairing kelas **simetris lintas tim** (partner kualitas sebanding di kelas yang sama). **Menghilangkan masalah carry (§2.C) secara struktural.**

**Format CLASSIC** (pasangan acak dari snapshot): tidak ada posisi tetap → expected per pemain terhadap **kedua** lawan (team-average, RD-aware). Carry tetap ada secara teoretis — ini informasi terbaik yang tersedia.

### 3.4 MoVM Ternormalisasi (margin terhadap target)

```
target = 21 (classic) | 30 (grup team, rally) | 42 (final team, rally)
m      = |scoreA − scoreB| / target
MoVM   = min(2.0, 0.5 + m)
```

| Format | Skor | m | MoVM |
|---|---|---|---|
| Classic | 21–19 | 0.095 | 0.60 |
| Team grup | 30–28 | 0.067 | 0.57 |
| Team final | 42–40 | 0.048 | 0.55 |
| Whitewash | 21–0 | 1.0 | 1.50 (cap 2.0) |

Aritmetika terverifikasi (Rev 2). MoVM lama M-DEF (21–19 → 0.64; 30–28 → 0.60) lebih berat untuk rally panjang; normalisasi membuatnya adil secara proporsional. **Catatan:** sesi/classic tournament menyimpan skor bebas target (22–30 sah, sampai 99); MoVM memakai `max(scoreA,scoreB)` sebagai denom-implisit via m — aman untuk skor apa pun yang tersimpan.

### 3.5 Phase Weight (turnamen)

Pengali delta (`w`), default — konfigurabel di `rating_config`:

```
classic: group 1.0 · qf 1.05 · sf 1.15 · 3rd 1.0 · final 1.25
team:    group 1.0 · final 1.25
```

### 3.6 RD Growth + Inactivity (pengganti decay M-DEF)

**Basis waktu = tanggal SUMBER (event `date`), BUKAN wall-clock.** `rating_players` menyimpan `last_played_at` yang di-set dari `date` event terakhir pemain; `hari_idle` dihitung dari selisih `date` antar event berturut-turut pemain (bukan `now() − last_played_at`). Ini menjamin **reproducibility**: replay/revert menghasilkan angka identik kapan pun dijalankan.

```
rd' = min(rd_max, sqrt(rd² + (c·hari_idle)²))
```

Kalibrasi (dari rd=30): ±6,4 hari → rd 100 · ±13 hari → rd 200 · ±23 hari → rd 350 (max). Untuk liga mingguan, jeda 1 pekan → rd≈109 (sedikit provisional), 1 bulan → rd 350 (full uncertainty). Masuk akal; **kalibrasi `c` final di P3** terhadap data riil. Decay rating tambahan (opsional, config): −5/minggu setelah 60 hari idle, berbasis `date`, floor 1000 — non-replayable pass terpisah bila diaktifkan (didokumentasikan sebagai non-deterministik).

### 3.7 Clamp & Finalisasi

- `r ∈ [1000, 2500]`, `rd ∈ [30, 350]` setelah update.
- **Cap delta per game** (`max_delta_per_game`, default 100 — dikalibrasi P3): tanpa cap, pemain
  provisional (rd=350) bisa swing ±300+ per game — perilaku Glicko standar untuk
  pemain baru, tapi dengan MoVM·w (maks 2.5×) bisa jadi ±800 pada whitewash
  final. Cap menjaga leaderboard stabil. (Rev 3.1)
- `peak_rating` = max(histori rating) dari audit trail `rating_deltas.new_rating` (bukan replay/perkiraan).
- Rounding: semua nilai (expected, movm, delta) di-round ke presisi penyimpanan dengan **satu code path yang sama** dipakai kalkulasi asli dan replay (bit-identical; §m3).

---

## 4. Urutan, Idempotency, Atomicity, Concurrency

### 4.1 Match Key — identitas STABIL (bukan hash konten yang bisa berubah)

Konten sumber (skor, nama, judul) **mudah diedit** di aplikasi nyata (optimistic mutation, autosave debounce, swap/rename/absent, edit skor kapan saja). Karena itu match_key TIDAK boleh bergantung pada konten yang bisa berubah. Identitas game yang benar:

```
match_key = sha256hex(
  kind | source_id | stable_game_id | sort(player_ids tim A) | sort(player_ids tim B)
  | scoreA | scoreB | target | phase | game_order
)
```

- `stable_game_id`:
  - **Team tournament**: kolom `tournament_team_matches.match_key` yang sudah dipersist (`g-1`…`g-9`, `final`).
  - **Classic tournament**: kolom `tournament_matches.match_key` yang sudah dipersist (`group-A-0`…`final-1`).
  - **Session**: **tidak ada id stabil** — gunakan `legacy_order` (indeks array schedule) yang **di-capture saat ingest**, bukan slot-court (posisi yang bergerak saat slot-swap). Regenerasi schedule menghancurkannya → terdeteksi oleh fingerprint (§4.4) → wajib revert.
- Nama → **canonical `player_id`** (resolve via `player_aliases`/`players` di dalam transaksi ingest, mirror `resolvePlayerAliases` store/session.go). Rename pemain tidak mengubah identitas.
- Skor masuk dalam key **untuk deteksi perubahan** (kombinasi dengan fingerprint), bukan sebagai satu-satunya mekanisme — edit skor = key berubah = fingerprint juga berubah → kena policy §4.4 (bukan double-count diam-diam).

### 4.2 Ordering (seq) — deterministik dari data sumber

```
UNIQUE (date, created_at sumber, source_id, game_order)
```

- `created_at` sumber = timestamp yang **di-capture saat ingest** (bukan dibaca ulang dari tabel live yang bisa berubah — store write-path hanya menyentuh `updated_at`).
- `game_order`: sesi = `(slot_index, court_index)`; tournament = match_index/partai index. Didefinisikan deterministik dari kolom sumber.
- `seq` kolom `bigserial` hanya **identitas padat**; urutan logis dari composite key di atas. Invariant: urutan commit = urutan seq (§4.3).
- Backfill data lama (banyak sesi satu transaksi, `created_at` identik) → diselamatkan oleh `source_id` sebagai tie-break (source_id unik per sesi/tournament).

### 4.3 Alur Ingest (satu transaksi, ALL-OR-NOTHING)

```
POST /ratings/ingest-session     { sessionId }
POST /ratings/ingest-tournament  { tournamentId }     // branch via TournamentFormat

1. BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ   (M9: hindari torn read sumber)
2. Ambil advisory lock global ingest (blocking pg_advisory_xact_lock, key "ratings_ingest")
3. Baca sumber: bm.sessions + scheduled_games (skor = kolom score_a/score_b di
   scheduled_games — TIDAK ada tabel game_scores), atau bm.tournaments + tabel team
4. Resolve nama → player_id via aliases; auto-register bm.players bila belum ada
   (INSERT ... ON CONFLICT DO NOTHING + re-select, pattern registerPlayerInTx)
5. Hitung source_fingerprint (hash kanonis seluruh sumber) → bandingkan rating_sources
   (§4.4): sama → no-op; beda → 409 SOURCE_CHANGED
6. Hitung match_key tiap game; skip yang sudah ada (idempotent)
7. Cek invariant seq: reject batch yang min seq ≤ max seq yang sudah ada (409 out-of-order)
8. Kumpulkan player_id, SORT, lock SELECT ... FOR UPDATE urut (deterministik, anti-deadlock)
9. Proses berurutan: Glicko (§3) → insert rating_events + rating_deltas
   + update rating_players + rating_sources
10. COMMIT — semua atau tidak sama sekali
```

- Kesalahan struktural (player unresolvable, format rusak) → ROLLBACK total (400, sertakan `game_ref`).
- Game "tidak playable" (skor belum lengkap / legacy aneh) → **skip game**, catat reason di respons `skipped`, transaksi lanjut (§M2).
- Konflik concurrent (55P03 / 40P01) → map ke retryable error via `mapRatingsError` (mirror `mapPublishError`).

### 4.4 Source Fingerprint & Edit Detection (WAJIB sebelum ingest aman)

Aplikasi nyata mengizinkan edit sumber kapan saja (skor, swap, rename, absent, reset grup, undian ulang). Tanpa deteksi, edit setelah ingest = double-count diam-diam.

```
source_fingerprint = sha256hex( representasi kanonis seluruh match list sumber,
                                setelah resolve player_id, diurutkan deterministik )

**Penting:** fingerprint memuat SEMUA game dari sumber — termasuk game yang
VOID (absent/placeholder, §8). "Void" hanya berarti tidak dihitung rating,
BUKAN berarti game itu dikeluarkan dari representasi sumber. Konsekuensi:
replace sub setelah ingest mengubah fingerprint → 409/auto_reconcile — tidak
ada double-count diam-diam.
```

- Disimpan di `rating_sources(source_id, source_kind, fingerprint, last_ingested_seq, ingested_at)` + per-baris di `rating_events.source_fingerprint`.
- Policy re-ingest:
  - source belum pernah di-ingest → proses.
  - fingerprint sama → **no-op** (`{processed: 0, skipped: N}`).
  - fingerprint beda → **409 `source_changed`** — wajib `revert-*` dulu (atau `auto_reconcile=true` di `rating_config`: hapus events source + re-ingest **dalam satu transaksi**), lalu **FULL REBUILD** (§4.4a).
- **Tidak ada partial re-ingest.** "Revert lalu re-ingest" adalah satu-satunya jalur perbaikan dan di-enforce, bukan opsional.
- Classic tournament: edit 1 skor grup mengubah bracket turunan (QF/SF/Final) → banyak match_key berubah → fingerprint menangkap seluruh tournament; policy = revert-tournament + re-ingest (32 match dihitung ulang).

### 4.5 Ingest Timing Policy (siapa memutuskan "final")

- **Session**: hanya ingest saat `status = 'locked'` (lock = gate rating). **Auto-lock saat ganti hari** (ABSENT_TBD_PLAYERS_DESIGN.md §4.6): sesi draft yang tanggalnya lewat otomatis di-lock oleh ticker backend → gate andal tanpa disiplin host. Unlock admin tetap ada — unlock setelah ingest → fingerprint akan beda → re-ingest ditolak sampai revert. Default config: `ingest_locked_only = true`.
- **Tournament**: TIDAK punya status/lock di backend → tambah flag admin `rating_sources.finalized` (endpoint/UI admin). Default: tournament hanya ingest saat `finalized = true`. **Auto-finalize tournament TIDAK dibuat** (Rev 3): bracket klasik turunan (edit skor grup mengubah pairing) dan undian team terjadi hari-H — auto-finalize berisiko mengunci data di tengah alur. Manual `finalized` = keputusan sadar admin.
- Backfill (P3): wajib `auto_reconcile` atau finalize semua sumber dulu.

### 4.4a FULL REBUILD setelah revert/reconcile (Rev 3.1 — KRITIS)

**Masalah:** rating bersifat **transitif melalui lawan**. Jika source X di-revert
(events-nya dihapus), events dari source LAIN yang diingest SETELAH X pada
awalnya dihitung di atas rating yang sudah memuat X. Menghapus X lalu hanya
mengganti events-nya — atau "replay per pemain" dengan **memakai ulang stored
delta** — menghasilkan rating yang menyimpang dari perhitungan segar (oponen
yang rating-nya ikut berubah karena X ikut mengubah rating mereka, dst.).

**Solusi — full rebuild:** setelah revert (atau auto_reconcile delete+reinsert):

```
1. DELETE rating_events/rating_deltas by source_id (revert) ATAU replace events (reconcile)
2. FULL REBUILD: recompute rating_players untuk SEMUA pemain dari
   SEMUA rating_events yang tersisa, urut by (date, created_at, source_id, game_order)
   — dari state default (r0/rd0), pakai fungsi murni + rounding yang sama (§3.7)
3. rating_deltas DITULIS ULANG (bukan reuse) — audit trail selalu konsisten
   dengan rating_players
```

- Biaya O(semua events) — ribuan baris, trivial; deterministik (ordering + basis
  waktu dari data sumber).
- `rating_players` TIDAK PERNAH disimpan dari hasil incremental tanpa rebuild
  penuh setelah setiap revert/reconcile.
- Transitivitas = alasan "replay per pemain terpengaruh" DITOLAK sebagai
  optimasi (affected set secara praktis bisa meluas ke semua pemain klub).

### 4.6 Concurrency — ringkasan

| Risiko | Mitigasi |
|---|---|
| Dua ingest overlap, urutan commit ≠ seq | Advisory lock global + invariant reject out-of-order (§4.3.2/7) |
| Deadlock AB-BA antar pemain | Lock player_id **sorted** + advisory lock global |
| Missing-row race (auto-register) | INSERT ON CONFLICT DO NOTHING + re-select dalam transaksi |
| Torn read sumber (publish koncurrent) | REPEATABLE READ |
| Revert vs ingest overlap | Keduanya ambil advisory lock yang sama |

### 4.7 Ekstensibilitas Format Baru (Rev 3)

Engine rating bersifat **agnostik jumlah pemain** (1v1 singles, 2v2 doubles, partai 6 pemain — semuanya baris `rating_deltas`; positional pairing otomatis menangani singles = counterpart 1 orang) dan **agnostik target** (MoVM menormalkan margin/target). Yang membuat engine format-specific hanyalah **ekstraksi sumber → daftar match mentah**.

**Kind Registry (Go, satu-satunya titik ekstensi):**

```
kind                    → extractor: ExtractMatches(source) → []RawMatch
                          + target (skor target valid)
                          + phases valid + phase_weights
                          + pairing strategy (positional | team-average | singles)
                          + player count per game (2/4/6 — informasi, bukan constraint)
```

Alur inti (match_key, seq, fingerprint, transaksi, lock, replay) **tidak berubah** untuk format apa pun. Menambahkan format baru =:

1. Implementasikan `ExtractMatches` untuk sumber baru (baca tabel format itu).
2. Tambah 1 entri ke registry (target, phases, pairing, player count).
3. Migration kecil HANYA jika ingin CHECK `kind`/`phase` diperluas — opsional (Rev 3 melonggarkan `target` ke `BETWEEN 1 AND 99` dan menghapus CHECK `phase`, sehingga kebanyakan format baru **tanpa perubahan schema**).
4. Rating pool tetap satu (pemain global) — format baru otomatis masuk ke rating yang sama.

`RawMatch` (kontrak minimal antar lapisan):

```
RawMatch { stable_game_id, date, kind, source_id,
           players: [{name | placeholder, team, position}],   -- NAMA (bukan id);
           scoreA, scoreB, target, phase }                    -- resolve → player_id
                                                              -- terjadi di pipeline ingest (§4.3.4)
```

Catatan: placeholder player (rate_as_unknown) dan absent (skip_game) berlaku sama di semua format — tidak ada logika format-specific di lapisan ingest.

---

## 5. Data Model (schema `bm`) — DDL terkoreksi Rev 2

```sql
-- 5.1 rating_players — state per pemain
CREATE TABLE bm.rating_players (
  player_id       uuid PRIMARY KEY REFERENCES bm.players(id),
  rating          numeric(8,2) NOT NULL DEFAULT 1250,
  rd              numeric(8,2) NOT NULL DEFAULT 350,
  peak_rating     numeric(8,2) NOT NULL DEFAULT 1250,
  games_played    integer     NOT NULL DEFAULT 0,
  wins            integer     NOT NULL DEFAULT 0,
  losses          integer     NOT NULL DEFAULT 0,
  last_played_at  date,                        -- dari event date (basis RD growth, bukan wall-clock)
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rating_players_rating_ck CHECK (rating BETWEEN 1000 AND 2500),
  CONSTRAINT rating_players_rd_ck     CHECK (rd BETWEEN 30 AND 350),
  CONSTRAINT rating_players_games_ck  CHECK (games_played = wins + losses)
);

-- 5.2 rating_events — idempotency + ordering + audit sumber
CREATE TABLE bm.rating_events (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  match_key         text UNIQUE NOT NULL,          -- §4.1 (termasuk source_id)
  seq               bigserial UNIQUE NOT NULL,     -- identitas padat; urutan = composite key
  kind              text NOT NULL CHECK (kind IN ('session','tournament_classic','tournament_team')),
  source_id         text NOT NULL,
  source_fingerprint text NOT NULL,                -- §4.4
  stable_game_id    text NOT NULL,                 -- match_key tournament / legacy_order sesi
  date              date NOT NULL,
  created_at        timestamptz NOT NULL,          -- capture saat ingest (ordering)
  game_order        text NOT NULL,                 -- (slot,court) / partai index — deterministik
  title             text NOT NULL,
  score_a           integer NOT NULL,
  score_b           integer NOT NULL,
  target            integer NOT NULL CHECK (target BETWEEN 1 AND 99),   -- Rev 3: loosened (format baru bebas target)
  phase             text NOT NULL,                 -- Rev 3: tanpa CHECK — valid per kind di Go registry
  phase_weight      numeric NOT NULL,
  processed_at      timestamptz NOT NULL,
  CONSTRAINT rating_events_order_uniq UNIQUE (date, created_at, source_id, game_order)
);
-- TIDAK ada team_a/team_b text[] — sisi diturunkan dari rating_deltas.team (§M5)

-- 5.3 rating_deltas — audit trail (satu baris per pemain per event)
CREATE TABLE bm.rating_deltas (
  event_id    uuid NOT NULL REFERENCES bm.rating_events(id) ON DELETE CASCADE,
  player_id   uuid NOT NULL REFERENCES bm.players(id),
  team        text NOT NULL CHECK (team IN ('A','B')),
  outcome     text NOT NULL CHECK (outcome IN ('W','L')),   -- draw tidak mungkin
  expected    numeric(8,4) NOT NULL,
  movm        numeric(8,4) NOT NULL,
  delta       numeric(8,2) NOT NULL,
  new_rating  numeric(8,2) NOT NULL,
  PRIMARY KEY (event_id, player_id)
);

-- 5.4 rating_sources — registry sumber + fingerprint (edit detection)
CREATE TABLE bm.rating_sources (
  source_id         text PRIMARY KEY,
  source_kind       text NOT NULL CHECK (source_kind IN ('session','tournament_classic','tournament_team')),
  fingerprint       text NOT NULL,
  finalized         boolean NOT NULL DEFAULT false,   -- gate ingest tournament
  last_ingested_seq bigint NOT NULL,
  ingested_at       timestamptz NOT NULL DEFAULT now()
);

-- 5.5 rating_config — tuning tanpa redeploy
CREATE TABLE bm.rating_config (
  key        text PRIMARY KEY,
  value      jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
-- Seed default di migration (initial_rating, initial_rd, rd_min/max, rd_growth_per_day,
-- rating_min/max, max_delta_per_game (100), movm_scale, movm_cap, phase_weights, decay_*,
-- ingest_locked_only, auto_reconcile, absent_policy (skip_game), placeholder_policy
-- (rate_as_unknown)). Loader Go: typed struct + validasi range (fail-fast di prod).

-- 5.6 Index
CREATE UNIQUE INDEX rating_events_match_key_idx ON bm.rating_events (match_key);
CREATE UNIQUE INDEX rating_events_seq_idx      ON bm.rating_events (seq);
CREATE INDEX rating_events_source_idx          ON bm.rating_events (source_id);
CREATE INDEX rating_deltas_player_idx          ON bm.rating_deltas (player_id, event_id);
CREATE INDEX rating_players_peak_idx           ON bm.rating_players (peak_rating DESC);
CREATE INDEX rating_players_rating_idx         ON bm.rating_players (rating DESC);
```

---

## 6. Kontrak API (majadu-api)

**Auth:** backend saat ini TIDAK punya lapisan auth. Tambah `MAJADU_ADMIN_TOKEN` (fail-fast di prod, config.go) + middleware `Authorization: Bearer <token>` untuk SEMUA endpoint write ratings. `internal/httperr` perlu `CodeUnauthorized` (401).

**Error contract:** envelope `{"error":{"code","message"}}` (konvensi `internal/httperr`). Map: source tidak ditemukan → 404 `not_found` · fingerprint beda → 409 `source_changed` · out-of-order/contention → 409 `conflict` · validasi → 400 `validation_error` (+ `game_ref`). Jangan meniru `mapPublishError` yang memetakan ErrContention → 400.

```
POST   /ratings/ingest-session     { sessionId }       → {processed, skipped:[{game_ref,reason}], players}
POST   /ratings/ingest-tournament  { tournamentId }    → {processed, skipped, players, warnings}
GET    /ratings/leaderboard        ?active&limit(100,max 500)&offset   → {total, rows:[{name,rating,rd,tier,peak,games,trend}]}
GET    /ratings/players/{playerId}                     → detail + history (sparkline data)
GET    /ratings/players/{playerId}/history             → [{date, delta, expected, movm, outcome, opponent, game_ref}]
POST   /ratings/revert-session     { sessionId }       → idempotent (source tanpa event = {processed:0})
POST   /ratings/revert-tournament  { tournamentId }    → idempotent (sama)
POST   /ratings/sources/{sourceId}/finalize            → set finalized (gate ingest tournament)
GET    /ratings/sources            ?changed=true       → daftar sumber yg fingerprint-nya divergen
GET    /ratings/status                                 → jumlah events, player ter-rating, last ingest
```

**Revert = hapus + FULL REBUILD** (bukan rollback snapshot — schema tidak
menyimpan pre-state): hapus `rating_events`/`rating_deltas` by `source_id`, lalu
**FULL REBUILD semua `rating_players` dari semua events tersisa** (§4.4a —
recompute, BUKAN reuse stored delta; transitivity melalui lawan). Pemain yang
tersisa 0 game → **reset ke default** (r0/rd0, zeros, NULL timestamp). Revert
source tanpa event = no-op sukses. Karena ordering & basis waktu deterministik
(§4.2/§3.6), full rebuild reproduksi angka identik dengan run asli. Replay
memakai `phase_weight` yang TERSIMPAN di `rating_events` (snapshot saat ingest —
perubahan config tidak retro-apply).

---

## 7. Tier Mapping (revisi dari M-DEF)

Band rating sederhana (D..S+), plus **badge provisional** saat `rd > 200`:

| Tier | Band rating |
|---|---|
| S+ | ≥ 1800 |
| S | 1700–1799 |
| A+ | 1600–1699 |
| A | 1500–1599 |
| B+ | 1400–1499 |
| B | 1300–1399 |
| C+ | 1200–1299 |
| C | 1100–1199 |
| D+ | 1050–1099 |
| D | < 1050 |

---

## 8. Edge Cases & Keputusan (berdasarkan perilaku APLIKASI NYATA)

| Kasus | Keputusan |
|---|---|
| **Skor belum ada** (played tapi unscored; partai null) | **Skip game** (bukan tolak batch); catat `played_unscored` |
| **Skor 0-0** | Tidak bisa disimpan di app (tie ditolak) — hanya legacy; skip |
| **Skor deuce 22–30** (sesi/classic) | **Sah** — MoVM menangani; JANGAN tolak |
| **Skor classic bebas target** (mis. 30-10) | **Sah** — tidak ada validasi target di classic; MoVM menangani |
| **Skor invalid sesi** (negatif / >99 / tie) | Legacy-only; **skip** (bukan tolak batch) |
| **Skor team invalid** (winner ≠ 30/42) | Backend sudah strict — data buruk = bug; **skip** + catat |
| **Pemain sama di kedua tim** | Skip game (guard) |
| **Pemain absent muncul di game berskor** | **`absent_policy = skip_game`** (default — game yang memuat ≥1 pemain absent = VOID, tidak diingest untuk siapa pun; konsisten dengan semantik absent di seluruh app, ABSENT_TBD_PLAYERS_DESIGN.md §4). Alternatif config: `skip_player` \| `count` |
| **Pemain placeholder (free/tbd/dst) di game** | **`placeholder_policy = rate_as_unknown`** (default — game diingest untuk pemain NYATA, placeholder diperlakukan pemain baru 1250/rd350 tanpa dipersist) \| `skip`. Placeholder TIDAK pernah punya rating |
| **Rename/swap pemain** | Identitas via player_id (§4.1); fingerprint mendeteksi perubahan sumber |
| **Edit skor sesi/tournament setelah ingest** | 409 `source_changed` → revert + re-ingest (atau auto_reconcile) |
| **Reset grup / undian ulang tournament** | Fingerprint beda → wajib revert-tournament |
| **Final team tidak sinkron standings** (group diedit setelah final) | Ingest verifikasi final pair vs standings top-2; mismatch → `warning` di respons, butuh keputusan admin |
| **Rubber 3 final (format team)** | Tetap diingest (ada skor) |
| **Re-import sumber identik** | No-op (fingerprint sama) |
| **Pemain baru di sumber** | Auto-register `bm.players` (TOCTOU-safe) + row `rating_players` baru |
| **Duplikat game dalam satu sumber** | match_key unik → dedupe otomatis |
| **Dua sesi se-date, judul sama, game identik** | match_key memuat `source_id` → tidak bertabrakan |

---

## 9. Perbandingan Fairness: M-DEF vs Proposal

| Dimensi | M-DEF | Proposal |
|---|---|---|
| Otoritas kalkulasi | Client (Dart) | Server (Go, transaksi REPEATABLE READ) |
| Atomicity | Per-RPC upsert buta | Batch all-or-nothing + advisory lock + seq invariant |
| Idempotency | Stable ID (klien, konten) | match_key berbasis source+player_id + source fingerprint |
| Edit setelah import | Double-count diam-diam | 409 source_changed / auto_reconcile |
| Urutan global | Nondeterministik (se-date) | (date, created_at, source_id, game_order) |
| Basis waktu | Wall-clock (non-reproducible) | Tanggal sumber (deterministik) |
| Uncertainty | K-tier lifetime | Glicko RD + RD growth |
| Struktur tim | Rata-rata (carry bias) | Positional pairing (team) |
| Margin | MoVM raw (bias rally) | m = margin/target, capped, simetris |
| Tournament | +8 flat | Phase weight |
| Decay | Per-import, global | RD growth berbasis tanggal sumber |
| Peak ELO | Replay perkiraan | Dari audit trail |
| Audit | player_deltas jsonb | rating_deltas relasional (per pemain) |
| Revert | Script manual | Endpoint idempotent, replay-from-scratch |

---

## 10. Task List (implementasi bertahap)

### P0 — Fondasi matematika & schema
- [x] 1. Migration `000008_rating_schema.sql` (nomor terakhir di VPS; 000007 terpakai placeholder): tabel §5 + seed `rating_config` (19 key) + index — **dibuat di VPS, diaplikasikan bm_dev + bm (5 tabel, 19 config)**
- [x] 2. `internal/domain/rating.go`: Glicko-1-lite murni (§3.1–3.4, 3.6) — fungsi murni, tanpa IO, satu code path rounding (`G`, `ExpectedScore`, `MarginOfVictory`, `GrowRD`, `GlickoUpdate`, clamp/cap/round2/round4)
- [x] 3. Golden unit tests: **10 test PASS** — golden pemain baru (delta 60 cap, rating 1310, rd 290.23), zero-sum state identik, cap whitewash final, clamp min/max, underdog > favorite, determinisme, round
- [x] 4. Unit test MoVM normalisasi (21-19/30-28/42-40/21-0/cap) — PASS
- [x] 5. `rating_config` loader: `store.LoadRatingConfig` (typed `domain.RatingConfig` + `Validate` fail-fast prod / fallback non-prod) — unit validate PASS

**Verifikasi P0:** `make check` hijau; golden test deterministik (double-run identik). → **lengkap: 90+ test domain PASS, gofmt clean. Audit P0: klaim "pool netral" §3.2 DIKOREKSI (Glicko bukan zero-sum — tiap pemain faktor sendiri).**

### P1 — Ingest (write path)
- [x] 6. `internal/store/rating.go`: REPEATABLE READ tx, advisory lock global, lock player sorted, invariant seq, upsert events/deltas/sources — satu transaksi → **implementasi lengkap; seq invariant via (date,created_at,source_id) tuple**
- [x] 7. Resolve nama → player_id + auto-register TOCTOU-safe (pattern `registerPlayerInTx`) → **`resolveRatingPlayers` (resolveTournamentPlayer)**
- [x] 7b. **Kind registry + `ExtractMatches` interface (§4.7)**: struktur `RawMatch`, registry entry per kind (target/phases/pairing) — dasar semua ingest → **`domain.KindRegistry` + `RawMatch` + `SourceFingerprint` + `MatchKey` (unit tested)**
- [x] 8. Ingest session: `legacy_order` capture, skip unscored, target 21, gate `locked` → **`extractSessionMatches` (legacy-<N> stable id, slot-court game_order)**
- [x] 9. Ingest tournament classic: branch via `TournamentFormat`, stable_game_id = match_key persisted, phase weight, gate `finalized` → **`extractClassicMatches`**
- [x] 10. Ingest tournament team: partai → 6 pemain, positional pairing (§3.3), target 30/42, verify final vs standings (warning) → **`extractTeamMatches` (partai = RawMatch, position per kelas, target 30/42) — verify final vs standings: P2 (warning)**
- [x] 11. Fingerprint: hitung + simpan; policy 409/auto_reconcile → **`SourceFingerprint` + `rating_sources`; `''` = belum diingest (finalize); revert invalidasi fingerprint (temuan audit)**
- [x] 12. `internal/handler/ratings.go` + `MAJADU_ADMIN_TOKEN` middleware + `CodeUnauthorized` + `mapRatingsError` → **handler + auth + error codes (unit tested) + routes**
- [x] 13. Integration test live: ingest sesi bm_dev → parity + determinisme (2× run identik); edit sumber → 409; auto_reconcile → bersih → **`TestIntegrationRatingIngestSession` + `GateLocked` PASS live (ingest→no-op→revert deterministik→409→reconcile)**

**Verifikasi P1:** `make check` hijau; re-run → no-op; edit → 409. → **lengkap: unit 100+ PASS, integration live PASS. Temuan audit P1: (a) pgx melarang 2 query paralel di satu tx → extractor dibaca-tuntas-dulu; (b) range-map = keys bukan values → bug uuid; (c) sequence butuh GRANT USAGE; (d) revert harus invalidasi fingerprint (kalau tidak re-ingest jadi no-op); (e) scan date → *time.Time.**

### P2 — Read path & revert
- [x] 14. `GET /ratings/leaderboard` (sort, tier, provisional badge, pagination, active) → **`RatingLeaderboard` + handler (limit default 100/max 500, offset, active = main 90 hari, trend = delta terakhir via lateral)**
- [x] 15. `GET /ratings/players/{id}` + history (sparkline) → **`RatingPlayer` + `RatingPlayerHistory` (desc by event date, limit)**
- [x] 16. `POST /ratings/revert-session` + `revert-tournament`: hapus by source_id + **FULL REBUILD semua rating_players** dari events tersisa (§4.4a — recompute, BUKAN reuse delta); reset pemain 0-game ke default; idempotent → **`RevertSource` (kind session/tournament) — full rebuild + reset-to-default + fingerprint invalidasi; idempotent (0 event = no-op)**
- [x] 17. `GET /ratings/sources?changed=true` + `POST .../finalize` → **`ListRatingSources` (event_count) + `SetSourceFinalized` (upsert; fingerprint '' = belum diingest) — `?changed=true` (re-extraction) ditunda ke P3**
- [x] 18. Integration test revert: state FULL REBUILD identik dengan fresh ingest; **test transitivity** (revert source A → rating pemain yang hanya main di source lain ikut ter-recompute benar); revert dua kali = no-op → **`TestIntegrationRatingReadPathAndTransitivity` PASS live: revert-A state == fresh B-only ingest state (identik bit-per-bit)**
- [x] 18b. Test `max_delta_per_game` cap (provisional rd=350 + whitewash final → delta ≤ cap) → **unit `TestGlickoUpdateCapWhitewashFinal` PASS**
- [ ] 18c. `rating_ingest_runs` audit log (opsional): riwayat ingest/reconcile/revert (mode, source, jumlah events, timestamp) → **didefer (P3/opsional — rating_sources sudah menyimpan ingested_at)**

**Verifikasi P2:** leaderboard konsisten dengan audit trail; revert → rating persis (full rebuild). → **lengkap: unit 100+ PASS, integration live PASS (ingest/no-op/409/reconcile/revert/transitivity/read path). Temuan audit P2: (a) runtime pemain baru harus di-init default (state {0,0} merusak math); (b) rebuildAll harus baca event→player mapping SEBELUM reset deltas; (c) cleanup test harus pakai share_code bukan id sesi; (d) asersi transitivity "berubah" tidak cukup — bandingkan state utuh vs fresh ingest.**

### P3 — Backfill & tuning
- [x] 19. Backfill: semua published session (locked) + tournament classic/team (finalize) dari bm → **`TestBackfillDev` PASS live (bm_dev): 27 source (26 sesi + 1 tournament classic) urut kronologis, 474 events, 106 pemain aktif. Temuan: UNION harus gabung sesi+tournament urut tanggal (tournament Mei gagal out-of-order saat diingest setelah sesi Juni); sesi test `it-rating*` disaring. `RebuildAll` ditambahkan (endpoint admin + store) sebagai tool tuning config.**
- [x] 20. Kalibrasi `c` (RD growth), `movm_scale`, `phase_weights` terhadap data riil → **temuan: cap 60 → 57% delta mentok di cap (avg_abs 49.9); dengan cap 100 → 29% (avg_abs 65.9) — distribusi lebih sehat. `max_delta_per_game` default 60→100 (seed migration 000008 + bm/bm_dev + doc di-update). Parameter lain tetap (rd0 350, c 15, movm 0.5/2.0)**
- [x] 21. Validasi fairness: korelasi tier vs winrate riil → **monotonik: A(≥1400) 0.776 · B 0.642 · C 0.473 · D 0.327 · E(<1100) 0.110 — sistem membedakan skill dengan benar**
- [x] 22. Catat parameter final ke `rating_config` → **bm_dev: max_delta=100; bm (prod): max_delta=100; seed migration patched**

**Verifikasi P3:** semua data historis ter-cover; no double-count; distribusi delta wajar.

### P4 — Frontend (opsional, scope terpisah)
- [ ] 23. Halaman leaderboard rating (tabel tier + badge provisional) di badminton-match
- [ ] 24. Player detail: sparkline rating + history
- [ ] 25. Admin: tombol ingest/revert/finalize (jika ada panel admin)

**Verifikasi P4:** UI render dari API; navigasi konsisten pola existing.

---

## 11. Catatan Integrasi M-DEF (BUKAN merge)

- Pipeline M-DEF (`020_majadu_import_rpc`) membaca schema `bm` di Supabase. Setelah badminton-match pindah ke VPS (`bm_dev`/`bm`), RPC itu hanya berfungsi jika di-recreate di VPS.
- Engine rating ini **tidak** memindahkan fitur M-DEF; hanya menyediakan data yang sama (match + skor) yang bisa dikonsumsi siapa pun.
- Keputusan akhir: apakah `rating_players` disinkronkan ke M-DEF, atau M-DEF pensiun setelah leaderboard rating lahir di badminton-match — dibuka untuk diskusi.

---

## 11.5 Rekalibrasi Param (Rev 3.2 — "leaderboard honest")

**Latar:** audit data bm_dev menemukan engine TIDAK pernah mencapai settled state —
median RD 148 (target rd_min 30 tak tercapai), median |delta| 58–66/match. Akar masalah:
`rd_growth=15/hari` membuat pemain mingguan teratchet ke rd~109+ antar sesi (growth 7 hari
= sqrt(rd²+11025)) sehingga shrink per game tidak sanggup mengejar → delta tetap panas,
rating = noise. Kalibrasi P3 sebelumnya hanya menyentuh max_delta (60→100 — malah makin
panas); rd_growth & initial_rd tidak dikalibrasi — diakui sebagai miss.

**Prinsip: leaderboard real/representatif/honest — bukan dihidupkan dengan mainan data.**
Parameter dipilih agar typical win (pemain mapan, game tipis vs seimbang) ≈ 10–12 poin.

| Param | Lama | Baru | Alasan |
|---|---|---|---|
| `rd_growth` | 15/hari | **3/hari** | Growth mingguan ~9 (bukan 105) → steady-state rd ≈ 55 |
| `initial_rd` | 350 | **200** | Swing pemain baru wajar; konvergensi tetap cepat |
| `max_delta` | 100 | **25–30** | 2–2.5× typical win; telak ≤ 0.3 band (band 100) |
| `rd_min` | 30 | 30 (tetap) | — |

**Verifikasi wajib setelah re-backfill:**
1. Median |delta| 5 game terakhir pemain mapan (≥30 game) ≈ 10–15.
2. Distribusi rd pemain mapan turun ke < 80 (mayoritas 40–70).
3. Simulasi: menang terus → 1 band (100 poin) dalam ±9 match.

Parameter tetap config-driven (`rating_config`) — tanpa migration ulang.

---

## 12. Log Revisi

- **Rev 3.3 (2026-08-18):** mekanisme season terintegrasi — `season_start` global (admin), ingest & rebuild memfilter match ≥ max(season_start, players.registered_at), forming = mid kelas sticky di match pertama, reset season = set tanggal + RebuildAll (semua balik ke mid kelas, kelas tetap). Per-player `registered_at` (awal journey). Referensi: RATING_TIERING_REVAMP.md §2.5.6-2.5.7.
- **Rev 3.1 (2026-08-18):** deep review lanjutan (kode nyata + matematika):
  1. **KRITIS — §4.4a FULL REBUILD**: revert/reconcile = hapus events + recompute SEMUA rating dari events tersisa (transitivity via lawan). "Replay per pemain" dengan reuse stored delta DITOLAK (bisa menyimpang). §6 revert + task P2 di-update.
  2. **§3.7 `max_delta_per_game`** (default 60): pemain provisional (rd=350) tanpa cap bisa swing ±300–800 per game (MoVM·w 2.5× pada whitewash final).
  3. **§4.7 RawMatch** membawa NAMA pemain (bukan id) — resolve di pipeline ingest.
  4. **Regex placeholder tidak konsisten** (kode): SQL `\?+$` tanpa anchor vs Go `^\?+$` → nama "Budi??" ikut void. DIPERBAIKI di `store/stats.go` + integration test PASS.
  5. `phase_weight` tersimpan = snapshot saat ingest (replay konsisten; config tidak retro-apply) — dinyatakan eksplisit di §6.
  6. Task list: test transitivity revert, test delta cap, `rating_ingest_runs` audit log.
- **Rev 3 (2026-08-18):** sinkronisasi absent/TBD + ekstensibilitas:
  1. `absent_policy` default `skip_game` (void, konsisten ABSENT_TBD §4); `placeholder_policy` = `rate_as_unknown` (config) — player placeholder tak pernah punya rating.
  2. Fingerprint memuat SEMUA game termasuk yang void (replace sub setelah ingest → 409/auto_reconcile).
  3. Gate ingest session memakai **auto-lock saat ganti hari** (bukan manual); tournament tetap manual `finalized` (auto-finalize DITOLAK — bracket turunan/undian hari-H).
  4. **Ekstensibilitas**: `target` CHECK dilonggarkan `BETWEEN 1 AND 99`, CHECK `phase` dihapus (validasi di Go registry), section baru §4.7 (Kind Registry + `ExtractMatches` interface + RawMatch) — format baru kebanyakan tanpa perubahan schema.
- **Rev 2 (2026-08-18):** review 3 sudut pandang:
  1. *Perilaku aplikasi nyata* — match_key harus berbasis identitas stabil + source_id (bukan konten); edit sumber = normal, wajib fingerprint + 409/auto_reconcile; absent tetap muncul di game (absent_policy); skor sesi/classic bebas target (skip vs reject); legacy_order untuk sesi; tidak ada tabel game_scores; lock sesi = gate ingest; tournament perlu finalized.
  2. *Atomicity/concurrency/data model* — rating_deltas PK komposit (event_id,player_id); advisory lock global + lock player sorted + invariant seq; REPEATABLE READ; RD growth basis tanggal sumber; revert replay-from-scratch; drop team_a/team_b → kolom team; MAJADU_ADMIN_TOKEN; mapRatingsError; config typed + seed; DDL terkoreksi.
  3. *Matematika* — MoVM·w simetris (scale seluruh update, pool netral); verifikasi aritmetika contoh; kalibrasi RD growth (6/13/23 hari); numeric stability aman; peak dari audit trail sound.
