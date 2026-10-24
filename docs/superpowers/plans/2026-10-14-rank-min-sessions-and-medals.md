# Plan: aturan min-sesi ranking + medal rank

Tanggal: 2026-10-14
Status: rencana (belum diimplementasi)

## Latar
Papan poin publik menampilkan pemain dengan sesi sangat sedikit, dan belum
ada penghargaan untuk pencapaian peringkat. Tujuan:
1. Sembunyikan pemain dengan sesi minim dari papan (configurable).
2. Tambah medal peringkat: "pernah mencapai rank N" dan "bertahan di 3 besar
   selama X pertandingan berturut-turut".

Fakta prod (2026-10-14):
- Papan bisa direkonstruksi historis dari `rating_deltas`: 30 tanggal event,
  2026-05-23 → 2026-10-10, 744 event.
- `rank_snapshots` hanya 3 tanggal (2026-09-27…10-10) → TIDAK dipakai untuk
  medal rank; hanya untuk panah movement.

## Bagian A — Aturan min-sesi (disetujui: ambang configurable, default 3)

### A1. Config
- `internal/domain/rating_config.go`: tambah `RankMinSessions int`;
  default `3` di `DefaultRatingConfig`; `Validate()` tolak `< 0`.
- `internal/store/rating_config.go`: `apply("rank_min_sessions", asInt(...))`.
- Migrasi `docs/backend/000022_rank_min_sessions.sql`:
  `INSERT INTO bm.rating_config (key,value) VALUES ('rank_min_sessions','3'::jsonb) ON CONFLICT DO NOTHING;`
  + baris index di `docs/backend/README.md`.

### A2. Filter
- `internal/store/rank_points.go` → `boardRowsFromEntries`: buang baris
  `EntriesAvailable < cfg.RankMinSessions` sebelum sort/rank/limit.
- Satu titik → board publik, `RankPointsForPlayer`, dan `CaptureRankSnapshot`
  konsisten. Rank dihitung ulang pada himpunan terfilter (kompak).

### A3. Frontend
- `src/queries/endpoints.ts`: expose `min_sessions` di `RankPointsBoard`
  (dan response per-pemain).
- `src/pages/RatingPlayerPage.tsx` (`RankPointsCard`): saat `row` kosong,
  copy → "Butuh minimal N sesi dalam 12 minggu untuk masuk ranking."
- `src/pages/RankingsPage.tsx`: header opsi tambah "· min N sesi".

### A4. Catatan
- Default 3 == `rank_thin_evidence_n` 3 → label "bukti masih tipis" praktis
  tak pernah muncul. Turunkan `rank_min_sessions` (mis. 1) bila label itu
  masih mau berguna.

## Bagian B — Medal rank

### B1. Model medal: arah perbandingan
Rank itu makin kecil makin baik; mesin medal sekarang mengasumsikan makin
besar makin baik. Tambah `Inverted bool` di `domain.MedalDef` dan tangani di:
- `TierForValue`: bila `Inverted`, level = i+1 selama `value <= Thresholds[i]`.
- `NextTarget`: tetap index-based (tak berubah).
- `insertAchievements` (`store/achievement.go`): upsert kini punya dua arah.
  Pisah batch: medal normal (`EXCLUDED.value > value` seperti sekarang) dan
  medal inverted (`EXCLUDED.value < value`, atau `value IS NULL`).
- `Detail`/display: medal inverted → "Best rank #N"; normal → "N unit".

### B2. Rekonstruksi timeline rank
Fungsi baru di `store` (mis. `rankTimeline(ctx, cfg)`):
- Ambil tanggal event unik (ascending) dari `rating_events`.
- Untuk tiap tanggal D: `entries := sessionEntries(cfg, D)`;
  `rows := boardRowsFromEntries(entries, cfg, names, 0)` (ikut filter min-sesi);
  catat `rank[playerID] = rank` pada D.
- Hasil: peta rank per pemain per tanggal.
- Catatan performa: ~30 boards × window 12 minggu; `popTierStrength` per
  panggilan — hoist bila perlu. Jalan tiap `BackfillAchievements` (yang
  dipanggil `RebuildAll`).

### B3. Medal reach (R1 — satu medal bertingkat) — DISETUJUI
- Key `medal:rank`, kind `rank`, Title "Rank", `Inverted: true`.
- `value` = best (minimum) rank yang pernah dicapai.
- `Thresholds` = `{10, 5, 3, 2, 1}` (Bronze=Top10 … Onyx=#1).
- `EarnedAt` = tanggal rank terbaik pertama kali diraih.

### B4. Medal streak (top-3, bertingkat) — DISETUJUI (top-3, ladder)
- Key `medal:rank_streak`, kind `rank`, Title "Top-3 Streak",
  Unit = "events" (lihat catatan definisi), arah normal (naik).
- `value` = run terpanjang berturut-turut (per tanggal event) dengan rank ≤ 3.
- `Thresholds` = usulan `{3, 5, 8, 12, 16}` (samakan dengan medal `streak`
  sesi yang sudah ada) — TBC.
- `EarnedAt` = tanggal ambang pertama tercapai.
- Catatan: "per tanggal event" (keputusan) → Sabtu & Minggu terhitung dua
  titik, jadi "minggu" sebenarnya "pertandingan". Unit memakai "events".

### B5. Hook
- `BackfillAchievements` (`store/achievement.go`): muat cfg, panggil
  `rankTimeline`, `addMedal` untuk reach + streak. Idempoten.
- Kind `rank` sudah diizinkan CHECK constraint `player_achievements` (000016).

### B6. Frontend
- `medalIcon` (`utils/achievementBadge.ts`): tambah glyph untuk
  `medal:rank` & `medal:rank_streak` (mis. crown/podium) + SVG di
  `AchievementBadge.tsx`.
- `AchievementDetailModal`: label tangga rank tampil `#10/#5/#3/#2/#1`.

## Migrasi
- Hanya `000022_rank_min_sessions.sql` (additive). Tidak ada perubahan
  skema medal.

## Urutan implementasi
1. Bagian A (min-sesi) — config, filter, FE, test.
2. B1 (model `Inverted` + upsert dua arah) + unit test.
3. B2–B5 (timeline + reach + streak + backfill) + test integration.
4. B6 (FE glyph/label).
5. Migrasi 000022 + apply.

## Risiko
- Medal rank bergantung data saat ini; revert/rename/delete menggeser hasil.
- `BackfillAchievements` jadi lebih berat (30 board) tiap rebuild.
- Salah arah perbandingan pada B1 = medal rank tak pernah naik (footgun utama).
- Bila kelak mau "minggu" kalender, ubah hanya di bucket timeline (satu titik).

## Keputusan yang masih perlu
- Threshold streak: `{3,5,8,12,16}` events — setuju?
- Judul/unit medal ("Rank", "Top-3 Streak", unit "events") — oke?
