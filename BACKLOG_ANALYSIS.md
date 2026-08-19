# BACKLOG_ANALYSIS.md — Kajian Detail Backlog: A5 · A6 · A10–A13 · B · O3 · O6

**Status:** ANALISIS — belum diimplementasikan
**Tanggal:** 2026-08-19
**Tujuan:** kajian mendalam tiap item backlog (dari `BACKLOG.md`) — kondisi kode
sekarang (terverifikasi), desain usulan, keputusan yang perlu diambil, effort,
risiko, dan rekomendasi. Basis keputusan sebelum mulai implementasi.
**Terkait:** `BACKLOG.md` (inventaris) · `RATING_ENGINE_DESIGN.md` · `RATING_TIERING_REVAMP.md`
· `ADMIN_MENU_PLAN.md` · `ABSENT_TBD_PLAYERS_DESIGN.md`

---

## Ringkasan Eksekutif

| Item | Effort | Nilai | Rekomendasi |
|---|---|---|---|
| **B** (stale checkbox, S1–S14) | ±15 mnt | Docs jujur | ✅ Kerjakan duluan |
| **O3** (M-DEF pensiun) | ±15 mnt | Keputusan final | ✅ Arsip + update docs |
| **A5** (rename player) | kecil | Tinggi (fix duplicate) | ✅ Kerjakan |
| **A11** (kalibrasi band) | kecil (script) | Sedang | ✅ Analisis dulu, kemungkinan no-op |
| **A10** (rebaseline) | sangat kecil | Sedang | ✅ Kerjakan |
| **A6** (team career stats) | medium | Sedang | 🟡 Setelah A5/A10 |
| **O6** (H2H & band promotion) | medium/kecil | Sedang/rendah | 🟡 Tunda (H2H paling konkret) |
| **A13** (decay) | medium + desain | Rendah | ⛔ Jangan aktifkan dulu |
| **A12** (audit log) | medium-kecil | Rendah | ⛔ Tunda |

---

## A5 — Endpoint Rename Canonical Player

### Kondisi sekarang (terverifikasi)

- `registerPlayerInTx` (`internal/store/tournament.go:480`) = resolve nama via
  `player_aliases.alias_name` (ternormalisasi: `lower` + `trim` + collapse
  whitespace, `domain.NormalizePlayerName`). Nama yang sudah ada sebagai alias →
  **merge** ke pemain yang sama. Nama baru → INSERT `players (canonical_name)` +
  alias.
- **Tidak ada mekanisme rename**: `players.canonical_name` tidak pernah berubah
  setelah registrasi. Satu-satunya cara "memperbaiki" nama = merge via register
  (kalau namanya sudah terlanjur salah, merge tidak membantu).

### Desain usulan

```
PATCH /players/{id}/name        (admin, AdminGuard)
body: { "name": "Nama Baru" }

1. Validasi:
   - name normal ≠ "" (NormalizePlayerName)
   - bukan placeholder (IsPlaceholderName) — jangan izinkan rename jadi "free"
   - ANTI-COLLISION: kalau NormalizePlayerName(name) sudah resolve ke player
     LAIN (via player_aliases) → 409 "name already taken by another player"
2. UPDATE players SET canonical_name = <baru> WHERE id = $1
3. INSERT player_aliases (player_id, alias_name = <normalize(nama lama)>)
   → referensi historis tetap resolve
4. COMMIT
```

### Kenapa aman untuk data historis

- `getPlayerStats` dan ingest resolve via `player_aliases` (bukan
  `canonical_name` langsung) → rename tidak memutus jejak sesi lama.
- Rating leaderboard memakai `player_id` (uuid) → **tidak terpengaruh**.
- URL `/player-history/:name` lama tetap jalan via alias.

### Dampak UI

- Tombol "Rename" di baris player `AdminPage` (prompt nama, pola sama dengan
  tombol Tier/Class yang ada).
- Pesan sukses: "Nama diubah + alias lama disimpan".

### Keputusan yang perlu diambil

1. Rename harus mempertahankan `tier`/`class`? → **Ya, otomatis** (bukan bagian
   dari rename).
2. Kalau nama lama = nama kanonik pemain lain (case-insensitive, normalized) →
   collision, ditolak.
3. Perlu juga menghapus alias lama yang sama dengan nama baru? → Tidak wajib
   (alias lama mengarah ke player ini, tidak berbahaya).

### Kompleksitas / Risiko

- **Effort:** kecil — 1 store method + 1 handler + 1 route + 1 tombol admin.
- **Risiko:** collision nama (di-handle anti-collision); rename ke nama yang
  sudah jadi alias player ini = no-op aman.
- **Bonus:** menjadi jalan keluar dari masalah **duplicate uuid** (nama varian):
  rename ke nama kanonik, lalu `DeletePlayer` duplikatnya (admin).

### Rekomendasi

**Kerjakan** — murah, dipakai admin, memperbaiki kualitas data.

---

## A6 — Team Player Career Stats

### Kondisi sekarang (terverifikasi)

- `computePlayerStats` (`internal/store/stats.go:70`) hanya mengaggregasi:
  - session stats (games, W/L, poin, partner, opponent) — query
    `session_players` + `scheduled_game_players`
  - classic tournament stats (`tournamentStats`) — tabel tournament classic
- **Tabel team TIDAK dibaca**: `tournament_team_players`, `tournament_team_matches`,
  `tournament_team_match_games` — pemain yang main di tournament format TEAM
  tidak tercatat di career stats sama sekali.

### Desain usulan

Blok query baru di `stats.go` untuk format team:

```
Per partai (tournament_team_match_games + join ke pemain per tim):
  - tiap pemain: W/L + poin for/against (score_a vs score_b di partai itu)
  - partner = rekan se-partai (kelas sama)
  - lawan = counterpart kelas sama di tim lawan
Void predicate: partai dengan player_id NULL (placeholder) → tidak dihitung
```

### Keputusan desain yang perlu diambil

| Opsi | Deskripsi | Catatan |
|---|---|---|
| **Section terpisah** `teamTournamentStats` | Terpisah dari classic `tournamentStats` | ⭐ Rekomendasi — semantik beda (partai vs match), frontend tinggal render tambahan |
| Gabung ke `tournamentStats` | Satu angka campur classic+team | Berisiko double-count / bingung kalau tanpa tag |

### Dampak UI

- `PlayerDetailPage`: render section team (mirip tournamentStats yang sudah ada).
- Response `GET /players/{name}/stats` ditambah field (backward compatible).

### Kompleksitas / Risiko

- **Effort:** medium — 3-4 query agregat + parity test (TS/Go) + UI.
- **Risiko:** semantik "1 partai = 1 game" beda dari classic; void predicate
  harus konsisten.

### Rekomendasi

**Kerjakan setelah A5/A10** — melengkapi Player History, tapi tidak mendesak
(hanya relevan kalau klub memakai format team).

---

## A10 — Rebaseline Endpoint

### Kondisi sekarang (terverifikasi)

- `SetPlayerClass` (`PATCH /ratings/players/{id}/class`) = ubah floor saja,
  **tanpa rebuild** — class bukan input Glicko.
- `SetPlayerTier` (`PATCH /players/{id}/tier`) = update class + **RebuildAll** →
  forming dari mid kelas **class yang dipreserve** (`rating_revert.go` `priorClass`).
  → Ganti tier induk **efektif sudah rebaseline**.
- Yang belum ada: rebaseline rating **tanpa mengubah kelas** (mis. admin ingin
  langsung set rating pemain ke nilai yang benar).

### Desain usulan

```
POST /ratings/players/{playerId}/rebaseline   (admin, AdminGuard)

1. Ambil rating_players: class (assigned)
2. newRating = MidRatingForClass(class)
   - class kosong/NULL → 400 "player has no assigned class" (atau pakai initial_rating?)
3. UPDATE rating_players SET
     rating = newRating,
     peak_rating = max(peak_rating, newRating)   ← keputusan
   WHERE player_id
4. TANPA rebuild — ingest berikutnya membaca state saat ini dan
   melanjutkan dari baseline baru secara alami
```

> ⚠️ Catatan penting (Rev 2 doc): desain awal "set + rebuild" SALAH — rebuild
> akan menimpa rating manual dari events. Hanya set langsung.

### Keputusan yang perlu diambil

1. `peak_rating`: rekomendasi `max(peak, newRating)` — hindari peak < rating.
2. `last_played_at` / `games_played` / `wins` / `losses`: **tidak diubah**
   (bukan reset, hanya baseline rating).
3. Efek terhadap history (`rating_deltas`): tidak disentuh — history tetap
   utuh, hanya state akhir yang digeser.

### Caveat yang wajib didokumentasikan

Rebaseline bersifat **"lunak"**: hilang saat `RebuildAll` / reset season
berikutnya (events tetap source of truth). Ini alat koreksi cepat admin,
bukan perubahan permanen. Kalau ingin permanen → set tier induk (yang
memang melakukan rebuild + forming baru).

### Kompleksitas / Risiko

- **Effort:** sangat kecil — 1 store method + 1 handler + 1 tombol admin.
- **Risiko:** user mengira ini permanen (harus jelas di UI: "efektif sampai
  rebuild berikutnya").

### Rekomendasi

**Kerjakan** — murah, melengkapi toolset admin (bersamaan dengan A5 bisa
satu putaran).

---

## A11 — Kalibrasi Lebar Band

### Kondisi sekarang (terverifikasi)

- Band 100 poin (`class_bands` di `rating_config`, rating_config.go:74-79):
  D- (≤1099) … A+ (≥2100).
- **Display-only**: band tidak memengaruhi math Glicko (Glicko hanya pakai
  rating + rd + skor). Ubah band = seed config, tanpa migration, tanpa rebuild.
- Delta settled ≈ 12.8/match → ±7.8 match per band (100/12.8). RD settled ≈ 58.

### Metode kalibrasi (murni analisis, tanpa ubah kode)

```
1. Query rating_deltas (audit trail) → rekonstruksi trajektori rating per pemain
2. Hitung frekuensi ganti sub-tier per pemain (per 10 game):
   - % crossing band boundary
   - frekuensi OSCILASI bolak-balik (D→D+→D dalam 3-4 game)
3. Kriteria keputusan:
   - pemain mapan (≥30 game) sering bouncing antar band → band terlalu sempit
     → naikkan (mis. 150) via rating_config
   - jarang pindah → biarkan 100
```

### Ekspektasi

Dengan delta 12.8 dan typical 7-8 match/band, band 100 kemungkinan besar
**sudah pas** (pindah band = pencapaian nyata ~2 sesi). Verifikasi empiris
tetap wajib sebelum memutuskan.

### Kompleksitas / Risiko

- **Effort:** kecil — script analisis (SQL atas `rating_deltas` + aggregasi).
- **Risiko:** hampir nol (display-only; kalau salah, tinggal set config kembali).

### Rekomendasi

**Buat script analisis-nya, putuskan setelah lihat angka.** Kemungkinan besar
hasil = "no-op / config tetap 100".

---

## A12 — `rating_ingest_runs` Audit Log

### Kondisi sekarang (terverifikasi)

- `rating_sources` menyimpan `ingested_at` + `last_ingested_seq` — cukup untuk
  tahu kapan source terakhir diingest.
- Tidak ada riwayat run (mode: ingest/revert/reconcile/rebuild).

### Desain usulan (kalau dikerjakan)

```sql
CREATE TABLE bm.rating_ingest_runs (
  id         bigserial PRIMARY KEY,
  mode       text NOT NULL,          -- ingest | revert | reconcile | rebuild | season_reset
  source_id  text,                   -- NULL untuk rebuild/season
  processed  integer NOT NULL,
  skipped    integer NOT NULL,
  players    integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
```

Insert di semua write path: `IngestSession`, `IngestTournament`,
`RevertSource`, `RebuildAll`, `CloseAndStartSeason` (+ migration 000011).

### Penilaian jujur

- **Nilai rendah untuk single-admin.** Debugging bisa direkonstruksi dari
  `rating_events.processed_at` + `rating_sources.ingested_at`.
- Yang tidak bisa dari data yang ada: riwayat mode + jumlah per run — tapi
  jarang dibutuhkan untuk skala klub.

### Rekomendasi

**Tunda** (kecuali ada masalah debugging berulang). Kalau dikerjakan:
1 migration + sentuh 4-5 path, medium-kecil.

---

## A13 — Decay Inactivity (base floor = kelas yang diassign)

### Kondisi sekarang (terverifikasi)

- Config sudah dimuat: `DecayEnabled=false`, `DecayThresholdDays=60`,
  `DecayPerWeek=5`, `DecayFloor=1000` (rating_config.go + store loader).
- **Tidak pernah diterapkan** di kode mana pun (hanya load + validasi).

### Base floor = kelas yang diassign — SUDAH OTOMATIS

`DisplayClass(rating, assigned)` (rating_config.go:200) = `max(derived, FloorOf(assigned))`.
→ Berapa pun decay-nya, pemain kelas B **tidak pernah tampil di bawah B-**.
Decay hanya menurunkan **angka rating** (di-floor 1000), badge kelas tetap.
Tidak ada perubahan desain yang dibutuhkan untuk ini.

### Masalah desain inti (WAJIB dipecahkan sebelum implementasi)

Decay = mutasi state yang **tidak diturunkan dari events** → `RebuildAll`
(deterministik dari events) **akan menghapusnya**. Tiga opsi:

| Opsi | Cara kerja | Sifat | Rekomendasi |
|---|---|---|---|
| **(a) Read-time effective rating** | Decay dihitung saat baca leaderboard/detail dari `last_played_at` + config; state tersimpan TIDAK diubah | Deterministik, replayable, zero storage | ⭐ Paling bersih |
| **(b) Pass non-replayable terpisah** (desain asli doc §3.6) | UPDATE `rating_players` langsung; wajib jalan ulang SETELAH setiap rebuild | Non-deterministik (documented) | Dipakai kalau (a) dianggap terlalu invasif |
| **(c) Decay masuk rebuildAll** | Langkah akhir rebuild berbasis tanggal events | Deterministik tapi perlu keputusan "referensi waktu" (season_start vs wall-clock) | Menengah |

### Pertanyaan kunci: apakah decay memang perlu?

- **RD growth SUDAH menghukum inaktivitas**: RD naik → badge provisional →
  magnitude update pemain itu terbatas (g(rd) kecil). Secara matematis,
  pemain yang jarang main sudah "dikurangi pengaruhnya".
- Decay rating menambah efek psikologis "rating turun kalau jarang main" —
  nilai sosial, bukan nilai statistik.

### Keputusan yang perlu diambil (kalau mau aktifkan)

1. Basis waktu: `date` sumber vs wall-clock (menentukan determinisme).
2. Reference point: kapan decay mulai (season_start? last_played_at?).
3. Interaksi dengan rebuild (pilih opsi a/b/c di atas).
4. Floor angka: 1000 (config) + floor display kelas (sudah otomatis).

### Kompleksitas / Risiko

- **Effort:** medium (tergantung opsi) + keputusan desain dulu.
- **Risiko:** melanggar invariant "rating deterministik" kalau salah opsi;
  rebuild bisa menghapus decay diam-diam.

### Rekomendasi

**Jangan aktifkan dulu.** RD growth sudah menangani inaktivitas. Kalau user
tetap mau: pilih **opsi (a) read-time** — paling aman. Floor kelas sudah
terjamin oleh desain yang ada.

---

## B — Stale Checkbox Cleanup (S1–S14)

### Kondisi sekarang

14 checkbox `[ ]` di 5 dokumen yang kodenya SUDAH ADA (rincian lengkap di
`BACKLOG.md` §3). Backlog asli? **Tidak** — ini murni docs lag.

### Daftar lengkap

| # | Lokasi checkbox | Dokumen |
|---|---|---|
| S1 | `ClassForRating` 12-band + floor + init + unit test | RATING_TIERING_REVAMP #2 |
| S2 | `rating_config`: ClassBands + SessionTierInit | RATING_TIERING_REVAMP #3 |
| S3 | Integration test player baru tier C → class C | RATING_TIERING_REVAMP #4 |
| S4 | Backfill class player existing | RATING_TIERING_REVAMP #9 |
| S5 | P4 frontend (leaderboard/detail/admin tombol) | RATING_ENGINE_DESIGN #23-25 |
| S6 | Update RATING_ENGINE_DESIGN (absent/placeholder/gate) | ABSENT_TBD #15 |
| S7 | Rating ingest policy void/placeholder + test | ABSENT_TBD #16 |
| S8 | Menu tournament list | roadmap #3 |
| S9 | Pertanyaan backend-go-decision (repo/kontrak/subdomain) | backend-go-decision §7 |
| S10 | Vercel env strategy | HANDOFF §5 |
| S11 | Backup cron VPS | HANDOFF §6 |
| S12 | Regression test fix | HANDOFF §6 |
| S13 | Fix isGoodQuality b2b | HANDOFF §6 |
| S14 | Drop kolom snapshot tournament | HANDOFF §6 |

### Aksi

Centang `[x]` + catatan status ringkas di tiap dokumen. Sinkronkan dengan
`BACKLOG.md` §3 sebagai acuan. **Jangan** mengubah isi selain status.

### Effort / Nilai

- **Effort:** ±15 menit.
- **Nilai:** dokumentasi jujur — mencegah kebingungan sesi berikutnya.

### Rekomendasi

**Kerjakan duluan** — paling murah, menghilangkan noise dari 8 item lain.

---

## O3 — M-DEF Pensiun (keputusan user: retire)

### Kondisi sekarang

- M-DEF = Flutter web app + Supabase + ELO sendiri (Dart), fitur dashboard /
  insights / matchup simulator. Repo: `/Users/user/Projects/mdef`.
- Dependensi: RPC `020_majadu_import_rpc` membaca schema `bm` di Supabase —
  **sudah tidak berfungsi** setelah Supabase pensiun (butuh recreate di VPS
  kalau mau dihidupkan).
- Majadu sudah punya leaderboard Glicko sendiri (deployed, live, 114 pemain).

### Implikasi keputusan "pensiun"

| Aspek | Aksi |
|---|---|
| **Kode M-DEF** | Tidak perlu recreate RPC. Repo di-archive (private / tag final + README note "superseded by Majadu /ratings") |
| **Data historis M-DEF** | Keputusan kecil: biarkan Supabase read-only / export / hapus — perlu konfirmasi user |
| **Komunikasi klub** | Pemain yang biasa buka M-DEF → arahkan ke `/ratings` Majadu |
| **Docs** | BACKLOG.md §4 O3/O4 → "decided: retire"; RATING_ENGINE_DESIGN §11 (opsi sync ke M-DEF) ditutup |
| **Fitur yang mungkin dirindukan** | Insights (most improved, streak, upset) + matchup simulator → kandidat O6/backlog Majadu kalau diminati |

### Effort / Risiko

- **Effort:** nyaris nol di Majadu (keputusan sudah diambil) — hanya arsip +
  update docs.
- **Risiko:** pemain klub masih pakai M-DEF → pastikan sosialisasi migrasi.

### Rekomendasi

**Lakukan aksi arsip + update docs.** Tidak ada perubahan kode Majadu.

---

## O6 — Fitur Rating Lain

### Analisis per fitur

| Fitur | Status faktual | Effort | Nilai |
|---|---|---|---|
| **Promosi/degradasi band** | **Sudah otomatis** — `class_display` bergerak bersama rating (floor mencegah turun kelas). Tambahan hanya sugar UI: badge "naik band!" di recent matches / history | kecil | rendah |
| **Perbandingan antar pemain (H2H)** | Belum ada. Data tersedia (`rating_deltas` + `rating_events`). Desain: `GET /ratings/compare?a=&b=` (H2H match history + rating sekarang) + halaman/modal kecil | medium | sedang (banter klub) |
| **Insights ala M-DEF** (most improved, streak, upset) | Belum ada; bisa di-port dari O3 | medium | sedang |

### Desain singkat H2H (kalau diminati)

```
GET /ratings/compare?a={playerId}&b={playerId}
→ { a: {name, rating, class_display}, b: {...},
    h2h: [{date, title, result_a, delta_a, delta_b}],   // dari rating_deltas/events
    summary: { a_wins, b_wins, draws } }
UI: `/ratings/compare?a=&b=` atau modal dari leaderboard (pilih 2 pemain)
```

### Rekomendasi

**Tunda.** Kalau mau dikerjakan: H2H paling konkret (nilai sosial tinggi,
effort medium). Promosi/degradasi **jangan** dikerjakan sebagai fitur
terpisah — sudah ada secara alami via `class_display`.

---

## Urutan Kerja yang Direkomendasikan

```
SEKARANG (murah, berdampak — satu putaran):
  1. B     — stale checkbox cleanup (±15 mnt)
  2. O3    — arsip repo mdef + update docs (±15 mnt)
  3. A5    — rename player endpoint (kecil, dipakai admin, fix duplicate)

SPRINT RATING (putaran berikutnya):
  4. A11   — script kalibrasi band (analisis → kemungkinan no-op)
  5. A10   — rebaseline endpoint (kecil, melengkapi admin)

LEBIH BESAR (setelah di atas, kalau prioritas masih relevan):
  6. A6    — team career stats (medium)
  7. O6    — H2H kalau diminati (medium)

JANGAN / TUNDA:
  8. A13   — decay: rekomendasi TIDAK aktifkan (RD growth sudah handle
             inactivity); floor kelas otomatis; kalau dipaksa → read-time
  9. A12   — audit log: nilai rendah untuk single-admin, skip
```

---

## Referensi

- `BACKLOG.md` — inventaris lengkap backlog/deferral (2026-08-19)
- `RATING_ENGINE_DESIGN.md` (Rev 3.3) — engine, revert, full rebuild, config
- `RATING_TIERING_REVAMP.md` (Rev 3.7) — tiering, forming, floor, season
- `ADMIN_MENU_PLAN.md` — admin area & endpoint admin
- `ABSENT_TBD_PLAYERS_DESIGN.md` — void/placeholder, auto-lock
- `docs/handbook/backend-go-decision.md` — keputusan backend Go
- Verifikasi kode: `majadu-api/internal/{store,handler,domain,cmd/server}` +
  `badminton-match/src/{pages,queries}`
