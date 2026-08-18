# RATING_ENGINE_DESIGN.md

**Status:** PROPOSAL — belum diimplementasikan
**Tanggal:** 2026-08-18
**Lokasi:** root badminton-match
**Referensi analisis:** M-DEF (`/Users/user/Projects/mdef`) — serap prinsip, BUKAN merge fungsionalitas.

---

## 1. Latar Belakang & Tujuan

M-DEF adalah leaderboard ELO badminton (Flutter + Supabase) dengan "MAJADU Dynamic-Elo Framework". Analisis menyimpulkan model rating-nya bagus secara konsep tetapi rapuh secara pelaksanaan dan kurang fair secara struktural. Dokumen ini mendesain **engine rating baru** untuk ekosistem Majadu (badminton-match + majadu-api) dengan prinsip:

1. **Server-authoritative** — perhitungan di backend Go dalam satu transaksi, bukan di client.
2. **Atomic** — satu batch masuk semua-atau-tidak-sama-sekali.
3. **Idempotent** — re-import/re-run tidak menggandakan efek.
4. **Fair** — uncertainty (RD) menggantikan K-tier; positional pairing untuk format team.
5. **Deterministik** — urutan pemrosesan global, hasil reproducible.
6. **Auditable** — delta per pemain per match tersimpan permanen.

Bukan merge: tidak ada fitur M-DEF yang dipindahkan. Yang diserap hanya *prinsip*: stable match key, peak ELO, revert terkontrol, tier, decay.

---

## 2. Kelemahan M-DEF → Solusi Desain Ini

| # | Kelemahan M-DEF | Solusi desain |
|---|---|---|
| A | ELO dihitung di client (Dart), DB hanya mirror | Hitung di Go, satu transaksi per batch |
| B | Ordering antar sesi se-date nondeterministik | Global `(date, created_at)` sequence |
| C | Team rating = rata-rata (masalah carry / varians) | Positional pairing di format team; RD-aware di classic |
| D | K-tier lifetime (8/12/24) tanpa konsep kepercayaan | Glicko RD (uncertainty) per pemain |
| E | MoVM tidak ternormalisasi terhadap target skor | `m = margin/target`, MoVM di-cap |
| F | Bonus tournament flat +8 tanpa bobot fase | Phase weight configurable |
| G | Decay global per-import (session-triggered) | RD growth berbasis waktu (deterministik) |
| H | Replay peak pakai rating saat ini (perkiraan) | Audit trail lengkap → peak dari history |
| I | Tidak bisa import format team baru | Ingest terpisah per format (classic/team) |

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
c      = 15     pertumbuhan RD per hari (kalibrasi, §3.6)

clamp rating: [1000, 2500]
```

### 3.2 Expected Score & Update per Pemain

Pemain `i` (tim A) melawan lawan `j` (tim B, 1–2 pemain; format team: hanya *counterpart langsung*, §3.3):

```
E_j   = 1 / (1 + 10^(−g(rd_j)·(r_i − r_j)/400))      expected vs tiap lawan
S     = 1 (menang) | 0 (kalah) | 0.5 (seri)           (seri tidak terjadi di badminton)
MoVM  = §3.4 (pengali margin)
w     = phase_weight (§3.5)

d²    = ( q² · Σ_j g(rd_j)² · E_j·(1−E_j) )⁻¹
r_i'  = r_i + ( q / (1/rd_i² + 1/d²) ) · Σ_j g(rd_j) · (MoVM·w·S − E_j)
rd_i' = sqrt( 1 / (1/rd_i² + 1/d²) )
```

Detail implementasi: `MoVM·w` mengalikan **S** (outcome), bukan E. Untuk yang kalah (S=0), delta murni dari `−E` — pertandingan tidak seimbang (favorite vs underdog) tidak menghukum underdog dua kali lipat.

### 3.3 Positional Pairing (team) vs Team-Average (classic)

**Format TEAM** (6 tim × 6 pemain, 3 partai per team-match): setiap partai adalah ganda `X+&X` vs `X+&X` (urutan: partai 1 = C+&C, partai 2 = A+&A, partai 3 = B+&B). Karena berpasangan **per kelas**, expected setiap pemain dihitung hanya terhadap **counterpart langsung**:

```
partai 1: (C+ A vs C+ B) dan (C A vs C B)
partai 2: (A+ A vs A+ B) dan (A A vs A B)
partai 3: (B+ A vs B+ B) dan (B A vs B B)
```

Fairness: pemain A+ tidak diuntungkan oleh partner C+ yang kalah; pemain C+ tidak dihukum karena expected dihitung dari lawan C+ sebenarnya. **Menghilangkan masalah carry (§2.C) secara struktural.**

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

MoVM lama M-DEF (21–19 → 0.64; 30–28 → 0.60) lebih berat untuk rally panjang; normalisasi membuatnya adil secara proporsional.

### 3.5 Phase Weight (turnamen)

Pengali delta (`w`), default — konfigurabel di `rating_config`:

```
classic: group 1.0 · qf 1.05 · sf 1.15 · 3rd 1.0 · final 1.25
team:    group 1.0 · final 1.25
```

### 3.6 RD Growth + Inactivity (pengganti decay M-DEF)

Saat pemain diproses, `hari_idle = now − last_played_at` (hari):

```
rd' = min(rd_max, sqrt(rd² + (c·hari_idle)²))
```

- Pemain baru/lama tidak aktif → RD tinggi → update besar saat kembali (kepercayaan turun, bukan rating dihukum −5/minggu).
- Pemain konsisten → RD menuju rd_min → update kecil (stabil).
- **Opsional (config)**: decay rating −5/minggu setelah 60 hari idle, berbasis waktu (bukan per-import), floor 1000 — agar leaderboard tidak beku.

### 3.7 Clamp & Finalisasi

- `r ∈ [1000, 2500]`, `rd ∈ [30, 350]` setelah update.
- `peak_rating` = max(histori rating) dari audit trail (bukan replay/perkiraan).

---

## 4. Urutan, Idempotency, Atomicity

### 4.1 Match Key (deterministik)

```
match_key = sha256hex(
  date | kind | title
  | sort(teamA names) | sort(teamB names)
  | scoreA | scoreB | target | game_order
)
```

- `game_order`: sesi = urutan slot-court; tournament = match index.
- Idempoten: import ulang sesi sama → no-op.

### 4.2 Global Sequence

```
seq = (date, created_at sumber, game_order)
```

- Dua sesi se-date → urut oleh `created_at` (insertion order) → deterministik.
- Disimpan di `rating_events.seq`, unik.

### 4.3 Alur Ingest (satu transaksi, ALL-OR-NOTHING)

```
POST /ratings/ingest-session     { sessionId }
POST /ratings/ingest-tournament  { tournamentId }     // classic | team otomatis

1. BEGIN
2. Baca sumber: bm.sessions + scheduled_games + game_scores, atau bm.tournaments
   + tabel team (tournament_teams/_team_matches/_team_match_games)
3. Bangun match list mentah (format-specific)
4. Hitung match_key tiap match; skip yang sudah ada di rating_events (idempotent)
5. Urutkan by (date, created_at, game_order)
6. Proses berurutan: SELECT ... FOR UPDATE per pemain di rating_players
   → hitung Glicko (§3) → tulis rating_deltas + rating_events + update rating_players
7. COMMIT — semua atau tidak sama sekali
```

- Kesalahan validasi mana pun → ROLLBACK total (atomic).
- Konflik concurrent ingest sesi berbeda yang memuat pemain sama → serialized via row lock; urutan ditentukan seq (bukan siapa datang duluan).

---

## 5. Data Model (schema `bm`)

### 5.1 `rating_players` — state per pemain

```
player_id       uuid PK → bm.players(id)
rating          numeric(8,2) NOT NULL DEFAULT 1250
rd              numeric(8,2) NOT NULL DEFAULT 350
peak_rating     numeric(8,2) NOT NULL DEFAULT 1250
games_played    integer     NOT NULL DEFAULT 0
wins            integer     NOT NULL DEFAULT 0
losses          integer     NOT NULL DEFAULT 0
last_played_at  timestamptz
last_processed  timestamptz          -- untuk RD growth
created_at, updated_at
```

### 5.2 `rating_events` — idempotency + urutan + audit sumber

```
id            uuid PK
match_key     text UNIQUE NOT NULL   -- §4.1
seq           bigint NOT NULL        -- §4.2
kind          text CHECK IN ('session','tournament_classic','tournament_team')
source_id     text NOT NULL          -- id sesi / id tournament
game_ref      text NOT NULL          -- 'slot-court' atau match id team
date          date NOT NULL
title         text NOT NULL
team_a        text[] NOT NULL        -- canonical names (urut tetap)
team_b        text[] NOT NULL
score_a       integer NOT NULL
score_b       integer NOT NULL
target        integer NOT NULL       -- 21 | 30 | 42
phase         text NOT NULL          -- 'group'|'qf'|'sf'|'3rd'|'final'|'regular'
phase_weight  numeric NOT NULL
processed_at  timestamptz NOT NULL
```

### 5.3 `rating_deltas` — audit trail (basis peak & history)

```
event_id    uuid PK → rating_events(id)
player_id   uuid NOT NULL → bm.players(id)
outcome     text CHECK IN ('W','L','D')
expected    numeric NOT NULL
movm        numeric NOT NULL
delta       numeric NOT NULL
new_rating  numeric NOT NULL
```

### 5.4 `rating_config` — tuning tanpa redeploy

```
key   text PK
value jsonb NOT NULL
```

Default keys: `initial_rating`, `initial_rd`, `rd_min`, `rd_max`, `rd_growth_per_day`,
`rating_min`, `rating_max`, `movm_scale`, `movm_cap`, `phase_weights` (jsonb),
`decay_enabled`, `decay_threshold_days`, `decay_per_week`, `decay_floor`.

### 5.5 Index

```
rating_events(match_key) UNIQUE
rating_events(seq) UNIQUE
rating_deltas(player_id, event_id DESC)
rating_players(peak_rating DESC)
rating_players(rating DESC)
```

---

## 6. Kontrak API (majadu-api)

Semua di bawah schema `bm`; write = admin, read = publik.

```
POST   /ratings/ingest-session     body {sessionId}      → {processed, skipped, players}
POST   /ratings/ingest-tournament  body {tournamentId}   → {processed, skipped, players}
GET    /ratings/leaderboard        ?active&limit&offset  → [{name, rating, rd, tier, peak, games, trend}]
GET    /ratings/players/{playerId}                        → detail + history (sparkline data)
GET    /ratings/players/{playerId}/history                → [{date, rating, delta, opponent, outcome}]
POST   /ratings/revert-session     body {sessionId}      → hapus events + rollback rating ke state sebelum sesi
GET    /ratings/status                                 → jumlah events, player ter-rating, last ingest
```

- `revert-session` = transaksi: hapus `rating_events` sesi itu (by source_id) → rebuild ulang rating untuk player yang terpengaruh dengan replay sisa history (deterministik, dari audit trail).

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

## 8. Edge Cases & Keputusan

| Kasus | Keputusan |
|---|---|
| Skor 0-0 (belum dimainkan) | Skip match (tidak diingest) |
| Skor invalid (negatif / > target+5) | Tolak **seluruh batch** (atomic) |
| Pemain sama di kedua tim | Skip match (guard) |
| Sesi/tournament diedit setelah ingest | Deteksi via `source_id` + fingerprint sumber; wajib revert lalu re-ingest manual |
| Rubber 3 final (format team) | Tetap diingest (ada skor) |
| Match grup tanpa skor | Diabaikan (menunggu lengkap) |
| Re-import sesi yang sama | No-op (match_key) |
| Pemain baru muncul di sesi | Auto-register `rating_players` (row baru, r0/rd0) |
| Absen / walkover | Tidak ada data skor → otomatis tidak ikut |

---

## 9. Perbandingan Fairness: M-DEF vs Proposal

| Dimensi | M-DEF | Proposal |
|---|---|---|
| Otoritas kalkulasi | Client (Dart) | Server (Go, transaksi) |
| Atomicity | Per-RPC upsert buta | Batch all-or-nothing + row lock |
| Idempotency | Stable ID (klien) | match_key (server) |
| Urutan global | Nondeterministik (se-date) | (date, created_at, game_order) |
| Uncertainty | K-tier lifetime | Glicko RD + RD growth |
| Struktur tim | Rata-rata (carry bias) | Positional pairing (team) |
| Margin | MoVM raw (bias rally) | m = margin/target, capped |
| Tournament | +8 flat | Phase weight |
| Decay | Per-import, global | RD growth berbasis waktu |
| Peak ELO | Replay perkiraan | Dari audit trail |
| Audit | player_deltas jsonb | rating_deltas relasional |

---

## 10. Task List (implementasi bertahap)

### P0 — Fondasi matematika & schema
- [ ] 1. Buat migration `000007_rating_schema.sql` (tabel §5 + index + config default)
- [ ] 2. `internal/domain/rating.go`: Glicko-1-lite (§3.1–3.4, 3.6) — murni, tanpa IO
- [ ] 3. Unit test golden: expected/delta/rd untuk skenario standar (favorite menang, underdog menang, whitewash, draw-impossible guard, clamp, RD growth)
- [ ] 4. Unit test MoVM normalisasi (21-19, 30-28, 42-40, 21-0) + phase weight
- [ ] 5. `rating_config` loader + override

**Verifikasi P0:** `make check` hijau; golden test reproduksi deterministik (double-run identik).

### P1 — Ingest (write path)
- [ ] 6. `internal/store/rating.go`: SELECT FOR UPDATE, upsert events, insert deltas — transaksi
- [ ] 7. Ingest session: baca sesi → match list (game_order dari slot-court, skip 0-0, target 21)
- [ ] 8. Ingest tournament classic: baca snapshot → 32 match (group/qf/sf/3rd/final, target 21)
- [ ] 9. Ingest tournament team: partai per team-match → 6 pemain, positional pairing (§3.3), target 30/42
- [ ] 10. Idempotency + seq global + rollback on error
- [ ] 11. `internal/handler/ratings.go`: endpoint §6 (ingest + status)
- [ ] 12. Integration test live: ingest sesi asli bm_dev → parity + determinisme (2× run hasil sama)

**Verifikasi P1:** `make check` hijau; live test ingest → query rating_events/deltas valid; re-run → skipped semua.

### P2 — Read path & revert
- [ ] 13. `GET /ratings/leaderboard` (sort, tier, active filter)
- [ ] 14. `GET /ratings/players/{id}` + history (sparkline)
- [ ] 15. `POST /ratings/revert-session` (hapus events + replay ulang)
- [ ] 16. Unit + integration test revert (state kembali identik)

**Verifikasi P2:** leaderboard konsisten dengan audit trail; revert → rating player kembali persis.

### P3 — Backfill & tuning
- [ ] 17. Backfill: ingest semua published session + tournament (classic + team) dari bm
- [ ] 18. Kalibrasi `c` (RD growth) & `movm_scale` terhadap data riil (distribusi delta sehat)
- [ ] 19. Validasi fairness: korelasi tier vs winrate riil (tidak ada pemain "inflated")
- [ ] 20. Catat hasil backfill + parameter final ke `rating_config`

**Verifikasi P3:** semua data historis ter-cover; tidak ada double-count; distribusi delta masuk akal.

### P4 — Frontend (opsional, scope terpisah)
- [ ] 21. Halaman leaderboard rating di badminton-match (tabel tier + badge provisional)
- [ ] 22. Player detail: sparkline rating + history
- [ ] 23. Tombol ingest/revert di admin (jika ada)

**Verifikasi P4:** UI render dari API; navigasi konsisten pola existing.

---

## 11. Catatan Integrasi M-DEF (BUKAN merge)

- Pipeline M-DEF (`020_majadu_import_rpc`) membaca schema `bm` di Supabase. Setelah badminton-match pindah ke VPS (`bm_dev`/`bm`), RPC itu hanya berfungsi jika di-recreate di VPS.
- Engine rating ini **tidak** memindahkan fitur M-DEF; hanya menyediakan data yang sama (match + skor) yang bisa dikonsumsi siapa pun.
- Keputusan akhir: apakah `rating_players` juga disinkronkan ke M-DEF, atau M-DEF pensiun setelah leaderboard rating lahir di badminton-match — dibuka untuk diskusi.
