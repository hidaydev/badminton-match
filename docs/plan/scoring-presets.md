# Scoring Presets — Rencana Teknis

Status: **planning only**. Dokumen ini tidak mengubah kode, migrasi, atau kontrak.
Tanggal: 2026-11-06
Lingkup: format skor per sesi (single game / best-of-3) di Majadu v2.
Di luar lingkup: turnamen dan preset custom oleh admin.

---

## Daftar isi

1. Ringkasan
2. Glosarium — "rating" itu apa dan dipakai di mana
3. Arsitektur skor hari ini (fakta + nomor baris)
4. Keputusan yang sudah dikunci
5. Konfigurasi
6. Model data
7. Engine aturan skor (modul murni)
8. Alur tulis & alur baca
9. API & kontrak
10. Dampak ke perhitungan poin (rating)
11. Simulasi angka
12. Standings
13. Achievement, share, export
14. UI: wizard, editor set, tampilan ringkas
15. Fase pengerjaan & kriteria terima
16. Rencana pengujian
17. Risiko, rollback, dan hal yang ditunda
18. Daftar berkas yang disentuh
19. Pertanyaan terbuka

---

## 1. Ringkasan

Tiga preset di gambar bukan sekadar "main sampai berapa poin". Ketiganya adalah
**format match**:

| Preset | Match | Set untuk menang | Poin | Deuce | Cap | Ganti sisi |
|---|---|---|---|---|---|---|
| MAJADU 30 | 1 set | 1 | 30 | tidak ada | 30 | 15 |
| Classic BO3 21 | best of 3 | 2 | 21 | 20–20 | 30 | 11 |
| New BWF BO3 15 | best of 3 | 2 | 15 | 14–14 | 21 | 8 |

Model sekarang menyimpan **satu pasang skor per slot** (`session.games.score_a/score_b`).
Itu tidak bisa menampung BO3: skor set kedua dan ketiga tidak punya tempat, dan
`gamesToWin` hanya akan jadi label.

Karena itu perubahan intinya:

> satu slot (round, court) = satu match; satu match berisi 1..3 set;
> set disimpan di tabel baru `session.game_sets`; semua pembaca memakai view
> `session.game_results` yang mengekspos pemenang, set, dan total poin.

Preset disimpan sebagai config (`session.scoring_presets`) dan di-*snapshot* ke
tiap sesi. Mengubah config preset di masa depan tidak pernah menulis ulang
sejarah; satu-satunya perubahan retroaktif adalah perbaikan target 21 → 30 di
rilis ini.

Sesi lama tetap terbaca sebagai satu set, tetapi poinnya dihitung ulang dengan
target 30 (format yang memang dimainkan), sehingga papan bergerak sekali saat
rilis. Untuk BO3, margin dinormalisasi per set supaya satu match BO3 tidak
otomatis bernilai tiga kali satu game.

Estimasi: P0 1–2 hari, P1 1 hari, P2 1–2 hari, P3 ½ hari. Total 4–6 hari kerja
efektif, tanpa menghitung review desain.

---

## 2. Glosarium — "rating" itu apa dan dipakai di mana

Pertanyaan ini perlu dijawab dulu karena istilahnya memang membingungkan.

**Tidak ada dua sistem.** Yang dipakai hanya satu: **rank point**. Di kode,
"rating" adalah nama modul dan tabel, bukan angka ELO terpisah.

Fakta yang bisa dicek:

- `rating.player_state` menyimpan **counter**: `games_played`, `wins`, `losses`
  (`modules/rating/infrastructure/ledger.nim:48-60`). Kolom `rating` sudah
  dihapus di migrasi `0026_drop_rating_ledger.sql`.
- Poin papan **tidak disimpan**; dihitung ulang setiap kali dibaca dari
  `session.games` dan `tournament.matches` (`modules/rating/projection.nim`).
- Satu-satunya angka poin yang tersimpan adalah snapshot harian
  `rating.snapshots.rating` (`db/migrations/0002_rating.sql:56-64`), dipakai
  untuk `prevRank`/`rankDelta` dan badge `rank_streak`.
- "Tier" (D, C, B, ...) bukan turunan poin. Ia disimpan di `player.players.tier`
  dan dipakai sebagai kekuatan lawan (`tierStrength`, `opponentMultiplier`).

Jadi jawaban singkatnya:

> rating = rank point. `rating.*` hanya nama modul. Poin dihitung saat dibaca,
> snapshot harian menyimpan hasilnya untuk melihat pergerakan peringkat.

Di mana angkanya muncul ke pengguna:

| Layar | Sumber |
|---|---|
| Papan peringkat | `read.boardRows` → `projection.project` |
| Profil pemain (breakdown) | proyeksi yang sama |
| `prevRank` / `rankDelta` | `rating.snapshots` |
| Badge `rank:*`, `rank_streak:*` | `rating.snapshots` + `player_state` |
| Jumlah game/menang/kalah di profil | `rating.player_state` |

Konsekuensi untuk fitur ini: **satu-satunya tempat format match menyentuh poin
adalah rumus `gameValue`** di proyeksi. Tidak ada delta tersimpan yang perlu
dimigrasi.

---

## 3. Arsitektur skor hari ini

Fakta yang relevan (semua sudah diverifikasi di kode):

- **Satu slot = satu game.** `session.games` punya `round_no`, `court_no`,
  `score_a`, `score_b`, `status` (`db/migrations/0001_core.sql:95-116`).
  Unique `(session_id, round_no, court_no)`; skor 0..99; `games_not_tied`
  menolak seri saat `status='played'`.
- **Tulis skor hanya di draft.** `gate()` menolak semua tulis kalau status bukan
  `draft` (`modules/session/schedule.nim:97-111`). Tulis memakai `If-Match`
  (versi sesi), lalu `bump()` menaikkan versi.
- **`setScore`** hanya menerima 0..99 dan menolak seri
  (`modules/session/schedule.nim:249-283`).
- **`setPlayed`** boleh menandai game played **tanpa skor** dan menghapus skor
  yang ada (`schedule.nim:284-317`). Artinya `status='played'` bukan bukti
  match selesai.
- **Pembaca skor** saat ini:
  - `modules/session/standings.nim` — standings per sesi.
  - `modules/rating/projection.nim:186-246` — poin papan.
  - `modules/rating/infrastructure/ingest.nim:96-110` — counter game/menang.
  - `modules/rating/read.nim:208-260` — riwayat & lawan/partner tersering.
  - `modules/achievement/infrastructure/backfill.nim:143-176` — badge volume.
  - `apps/api/src/app.nim` — detail sesi (`~2035`), game (`~2085`),
     share (`~2150`).
- **Rating memakai target 21 untuk semua sesi** (`rating.score_target`), padahal
  sesi dimainkan sampai 30. Margin 30–29 sudah dianggap penuh, dan 30–5
  tersaturasi. Ini bug yang diperbaiki fitur ini, dan karena poin dihitung saat
  dibaca, perbaikannya berlaku retroaktif.

Konsekuensi: setiap pembaca di atas harus pindah ke satu sumber baru. Kalau
tidak, BO3 akan terbaca sebagai "total poin" dan pemenang bisa salah.

---

## 4. Keputusan yang sudah dikunci

| # | Keputusan | Alasan |
|---|---|---|
| 1 | Normalisasi rating BO3 = rata-rata margin per set | Format-neutral; satu set identik dengan rumus lama |
| 2 | Satu match BO3 = **1 game** untuk standings & achievement | "Game" berarti match yang dimainkan, bukan set |
| 3 | Preset boleh diganti selama belum ada set | Setelah ada set, harus dikosongkan dulu |
| 4 | Hanya tiga preset resmi | Preset keempat = perubahan config, bukan rilis |
| 5 | Turnamen di luar lingkup | Format turnamen punya aturan poin sendiri |
| 6 | Detail per set ditampilkan | Skor 2–1 tanpa rincian set tidak bisa diverifikasi |
| 7 | Set parsial boleh disimpan, tidak dihitung | Operator sering mengisi jeda antar set |
| 8 | Sesi lama juga dinilai dengan target 30 | Formatnya memang MAJADU 30; target 21 adalah bug |

Catatan untuk #3: karena semua tulis skor hanya boleh di `draft`, aturan
"belum ada set" cukup menjadi guard tambahan di `PATCH /sessions/{id}`.
Mengosongkan set (body `{"sets": []}`) membuka kembali pilihan preset.

Catatan untuk #8: keputusan ini **retroaktif**. Poin sesi lama dihitung ulang
dengan target 30 saat papan dibaca, karena poin memang tidak disimpan. Total
poin satu match tetap 250 (sebelum multiplier); yang berubah adalah pembagian
antara pemenang dan lawan. Konsekuensi dan angkanya ada di §10–11.

---

## 5. Konfigurasi

### 5.1 Key baru

| Key | Tipe | Scope | Default | Batas | Fungsi |
|---|---|---|---|---|---|
| `session.scoring_presets` | json | platform | 3 preset resmi | array 1..20 | Definisi format yang boleh dipilih |
| `session.default_scoring_preset` | string | **community** | `majadu30` | harus id yang ada | Pilihan awal di wizard |

Keduanya masuk `modules/platform/config/registry.nim`, `db/seeds/platform_config.sql`,
dan migrasi. `session.default_scoring_preset` sengaja community-scoped supaya
satu komunitas bisa default ke BWF tanpa mengubah default platform.

### 5.2 Bentuk JSON

```json
[
  {
    "id": "majadu30",
    "label": "MAJADU 30",
    "gamesToWin": 1,
    "pointsToWin": 30,
    "winBy": 1,
    "deuceAt": null,
    "maxPoints": 30,
    "changeEndsAt": 15
  },
  {
    "id": "classic21",
    "label": "Classic BO3 21",
    "gamesToWin": 2,
    "pointsToWin": 21,
    "winBy": 2,
    "deuceAt": 20,
    "maxPoints": 30,
    "changeEndsAt": 11
  },
  {
    "id": "bwf15",
    "label": "New BWF BO3 15",
    "gamesToWin": 2,
    "pointsToWin": 15,
    "winBy": 2,
    "deuceAt": 14,
    "maxPoints": 21,
    "changeEndsAt": 8
  }
]
```

Field:

- `id` — `[a-z0-9_]{2,32}`, unik, bukan `legacy_v1` (reserved).
- `label` — teks yang ditampilkan di wizard; tidak diterjemahkan (nama format).
- `gamesToWin` — set yang harus dimenangkan (1 = single match).
- `pointsToWin` — poin untuk menang set tanpa deuce.
- `winBy` — selisih minimum; untuk MAJADU 30 nilainya 1 (tanpa deuce).
- `deuceAt` — skor lawan saat aturan `winBy` mulai berlaku; `null` = tidak ada
  deuce.
- `maxPoints` — cap. Saat cap tercapai, selisih 1 sudah cukup.
- `changeEndsAt` — hanya petunjuk UI ("ganti sisi di 11"), tidak memengaruhi
  data atau validasi.

`ratingTarget` sudah tidak ada: `pointsToWin` **adalah** target penilaian.
`mode` juga tidak ditulis di config; preset dari config selalu `"preset"`, dan
hanya snapshot `legacy_v1` yang memakai `"legacy"`.

### 5.3 Validasi saat load

`loadSnapshot` sudah menolak start kalau ada key hilang/tipe salah. Tambahkan
validasi untuk key JSON ini (fungsi `parsePresets` di `modules/session/scoring.nim`,
dipanggil dari `modules/platform/config/store.nim`):

| Aturan | Pesan |
|---|---|
| array, panjang 1..20 | `session.scoring_presets must be a non-empty array (max 20)` |
| `id` cocok regex, unik, bukan `legacy_v1` | `duplicate preset id: x` |
| `gamesToWin` 1..5 | `preset x: gamesToWin must be 1..5` |
| `pointsToWin` 1..99 | `preset x: pointsToWin must be 1..99` |
| `winBy` 1..10 | `preset x: winBy must be 1..10` |
| `maxPoints` ≥ `pointsToWin`, ≤ 99 | `preset x: maxPoints must be at least pointsToWin` |
| `deuceAt` null atau `pointsToWin-1 .. maxPoints-1` | `preset x: deuceAt is out of range` |
| `changeEndsAt` null atau 1..`pointsToWin-1` | `preset x: changeEndsAt is out of range` |
| `default_scoring_preset` ada di array | `default preset not found: x` |

Semua gagal **saat start**, bukan saat request. Ini konsisten dengan filosofi
config repo: tidak ada default tersembunyi di kode.

Validasi override komunitas dilakukan di route settings saat menulis:
`session.default_scoring_preset` harus id yang ada di preset platform saat itu.
Kalau tidak → `400 INVALID_CONFIG`. Tidak ada fallback diam-diam saat
`createSession`: id yang sudah tidak ada di config → `400 INVALID_PRESET`.
Ini mencegah sesi lahir dengan format yang tidak bisa dijelaskan ke pengguna.

### 5.4 Snapshot per sesi

`session.sessions` menyimpan dua kolom:

- `scoring_preset text` — id.
- `scoring_rules jsonb` — salinan penuh aturan.

Contoh snapshot untuk sesi baru:

```json
{
  "id": "classic21",
  "label": "Classic BO3 21",
  "mode": "preset",
  "gamesToWin": 2,
  "pointsToWin": 21,
  "winBy": 2,
  "deuceAt": 20,
  "maxPoints": 30,
  "changeEndsAt": 11
}
```

Snapshot untuk sesi lama (dibuat oleh migrasi):

```json
{
  "id": "legacy_v1",
  "label": "v1 scoring",
  "mode": "legacy",
  "gamesToWin": 1,
  "pointsToWin": 30,
  "winBy": 1,
  "deuceAt": null,
  "maxPoints": 99,
  "changeEndsAt": 15
}
```

`mode: "legacy"` adalah satu-satunya cabang khusus: validasi set hanya
"0..99 dan tidak seri", persis perilaku v1. Tanpa flag ini, membuka kembali
sesi lama untuk memperbaiki skor 21–19 akan ditolak oleh aturan 30 poin.

**Sesi lama = sesi MAJADU 30, jadi dinilai dengan target 30.** Sebelumnya
penilaian memakai `rating.score_target = 21`; itu bug, dan karena poin tidak
disimpan, perbaikan ini otomatis berlaku retroaktif saat papan dibaca. Tidak
ada migrasi poin; yang perlu disadari hanya pergerakan papan (§10–11).

`legacy_v1` **tidak pernah** ada di `session.scoring_presets`, sehingga tidak
bisa dipilih di wizard dan tidak bisa dipakai `PATCH`.

### 5.5 Kenapa snapshot, bukan referensi

Kalau sesi hanya menyimpan id, lalu operator mengubah `pointsToWin` atau
menghapus preset, sesi lama berubah arti (skor yang dulu sah jadi tidak sah,
poin berubah). Snapshot membuat aturan menjadi bagian dari data hasil, sama
seperti `rating.events.local_date` menyimpan tanggal saat hasil dikunci.

Efek sampingnya: mengganti config preset hanya memengaruhi sesi **baru**.
Itu disengaja dan perlu disebut di handbook.

### 5.6 Cara klien membaca daftar preset

`session.scoring_presets` adalah key **platform**, sehingga tidak muncul di
`effective` (yang hanya berisi key community-scoped). Wizard butuh daftarnya
sebelum sesi dibuat.

Solusi: `GET /c/{slug}/config` menambahkan field referensi **read-only**:

```json
{
  "effective": { "...": "..." },
  "scoringPresets": [
    {"id": "majadu30", "label": "MAJADU 30", "gamesToWin": 1, "pointsToWin": 30,
     "winBy": 1, "deuceAt": null, "maxPoints": 30, "changeEndsAt": 15}
  ]
}
```

- Bukan setting; tidak bisa ditulis lewat `PATCH /c/{slug}/settings`.
- Isinya sama untuk semua komunitas; default per komunitas tetap diambil dari
  `effective["session.default_scoring_preset"]`.
- Kalau nanti preset boleh berbeda per komunitas, field ini yang berubah tanpa
  mengubah bentuk `effective`.

Di klien, `community/api.ts` (`fetchCommunityConfig`) dan
`community/useCommunityConfig.ts` diperluas supaya mengembalikan
`{ effective, scoringPresets }`; wizard dan `SettingsPage` memakai hook yang
sama. Ini menghindari endpoint baru dan memastikan kedua layar melihat daftar
yang identik.

Konsekuensi parity: satu case config berubah (field baru). Tidak ada operasi
baru; tetap 75 operasi.

---

## 6. Model data

### 6.1 Migrasi `0029_scoring_presets.sql`

```sql
-- 0029: one slot is one match, and a match is a list of sets.
--
-- The flat score columns stay for one release: they are the backfill source
-- and the rollback path. Nothing writes them after this migration; every
-- reader moves to session.game_results.

alter table session.sessions
  add column scoring_preset text not null default 'legacy_v1',
  add column scoring_rules jsonb not null default '{
    "id": "legacy_v1",
    "label": "v1 scoring",
    "mode": "legacy",
    "gamesToWin": 1,
    "pointsToWin": 30,
    "winBy": 1,
    "deuceAt": null,
    "maxPoints": 99,
    "changeEndsAt": 15
  }'::jsonb;

alter table session.games
  add constraint games_identity_unique
  unique (community_id, session_id, round_no, court_no);

create table session.game_sets (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  session_id uuid not null,
  round_no integer not null,
  court_no integer not null,
  set_no integer not null,
  score_a integer not null,
  score_b integer not null,
  created_at timestamptz not null default now(),
  constraint game_sets_match_fk
    foreign key (community_id, session_id, round_no, court_no)
    references session.games (community_id, session_id, round_no, court_no)
    on delete cascade,
  constraint game_sets_set_unique
    unique (session_id, round_no, court_no, set_no),
  constraint game_sets_set_no_check check (set_no between 1 and 9),
  constraint game_sets_score_range check (
    score_a between 0 and 99 and score_b between 0 and 99),
  constraint game_sets_not_tied check (score_a <> score_b)
);

insert into session.game_sets
  (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
select community_id, session_id, round_no, court_no, 1, score_a, score_b
from session.games
where score_a is not null and score_b is not null;
```

Konfigurasi ikut migrasi yang sama (pola `0028_config_cleanup.sql`):

```sql
insert into platform.config
  (key, value_type, value, min_value, max_value, scope, description)
values
  ('session.scoring_presets', 'json',
   '[{"id":"majadu30",...},{"id":"classic21",...},{"id":"bwf15",...}]',
   null, null, 'platform', 'Selectable match formats'),
  ('session.default_scoring_preset', 'string', '"majadu30"',
   null, null, 'community', 'Format chosen by default in the session wizard')
on conflict (key) do update set
  value_type = excluded.value_type,
  value = excluded.value,
  min_value = excluded.min_value,
  max_value = excluded.max_value,
  scope = excluded.scope,
  description = excluded.description;

-- The session target now comes from each session's snapshot. Keep this key only
-- as a fallback, but make the fallback match the format people actually play.
update platform.config
   set value = '30'
 where key = 'rating.score_target';

update platform.config_version set version = version + 1;
```

Seed (`db/seeds/platform_config.sql`) memakai nilai yang sama dengan
`on conflict do nothing`, sehingga DB baru dan DB lama berakhir identik.
`rating.score_target` di seed juga menjadi 30.

Catatan:

- `games_identity_unique` diperlukan PostgreSQL untuk FK komposit; isinya
  redundan dengan `games_round_court_unique` tetapi kolomnya harus persis sama
  dengan yang direferensikan.
- `session_id` sudah uuid global, jadi `community_id` di FK adalah lapisan
  pertahanan tambahan, bukan kebutuhan teknis.
- Backfill hanya mengambil baris yang punya **kedua** skor. Game `played`
  tanpa skor (hasil `setPlayed`) tetap tidak punya set, persis seperti hari ini
  ia tidak dihitung.
- Backfill tidak menyentuh `status`; game yang dulu `scheduled` tapi punya skor
  (tidak mungkin lewat API) tetap ikut, dan pembaca tetap memfilter status.

### 6.2 View `session.game_results`

Satu sumber untuk semua pembaca:

```sql
create view session.game_results as
select
  g.id,
  g.community_id,
  g.session_id,
  g.round_no,
  g.court_no,
  g.status,
  g.side_a1,
  g.side_a2,
  g.side_b1,
  g.side_b2,
  s.scoring_preset,
  (s.scoring_rules->>'gamesToWin')::int     as games_to_win,
  (s.scoring_rules->>'pointsToWin')::int    as points_to_win,
  coalesce(t.sets_played, 0)                as sets_played,
  coalesce(t.sets_a, 0)                     as sets_a,
  coalesce(t.sets_b, 0)                     as sets_b,
  coalesce(t.points_a, 0)                   as points_a,
  coalesce(t.points_b, 0)                   as points_b,
  case
    when coalesce(t.sets_a, 0) >= (s.scoring_rules->>'gamesToWin')::int then 'a'
    when coalesce(t.sets_b, 0) >= (s.scoring_rules->>'gamesToWin')::int then 'b'
    else ''
  end                                        as winner
from session.games g
join session.sessions s
  on s.community_id = g.community_id and s.id = g.session_id
left join lateral (
  select count(*)::int                                          as sets_played,
         count(*) filter (where x.score_a > x.score_b)::int     as sets_a,
         count(*) filter (where x.score_b > x.score_a)::int     as sets_b,
         sum(x.score_a)::int                                    as points_a,
         sum(x.score_b)::int                                    as points_b
  from session.game_sets x
  where x.community_id = g.community_id
    and x.session_id = g.session_id
    and x.round_no = g.round_no
    and x.court_no = g.court_no
) t on true;
```

Arti kolom:

- `sets_a`/`sets_b` — jumlah set yang dimenangkan, bukan poin.
- `points_a`/`points_b` — total poin semua set; inilah yang dipakai standings
  sebagai `pointsFor`/`pointsAgainst`.
- `winner` — `'a'`/`'b'` hanya kalau match sudah mencapai `gamesToWin`; string
  kosong untuk match parsial atau game tanpa set.
- `points_to_win` — target penilaian yang dibekukan untuk sesi itu.

Invariant yang harus dijaga engine: `winner <> ''` menyiratkan
`sets_played >= games_to_win` dan `sets_a = games_to_win` atau
`sets_b = games_to_win`.

Catatan performa: lateral aggregate memakai index unik
`(session_id, round_no, court_no, set_no)`, dan semua pembaca memfilter
`community_id` + `session_id` (atau window tanggal lewat `rating.events`)
sebelum join. Untuk ukuran komunitas sekarang (40 sesi, ~150 pemain) biayanya
tidak terasa; kalau nanti perlu, view bisa dijadikan materialized view tanpa
mengubah pembaca.

### 6.3 Kolom lama

`session.games.score_a/score_b`:

- **tidak ditulis lagi** setelah P0 (termasuk `setScore`, `setPlayed`, `swap`);
- tetap ada sebagai sumber backfill dan jalur rollback;
- dibaca hanya oleh migrasi, bukan runtime.

`games_not_tied` tetap ada dan aman: kolomnya `null` untuk semua baris baru,
dan constraint hanya berlaku saat keduanya terisi.

Drop direncanakan di migrasi lanjutan (P4, setelah satu rilis):
`alter table session.games drop constraint games_not_tied, drop column score_a, drop column score_b;`
Tidak dilakukan di 0029 supaya rollback masih mungkin sebelum ada sesi BO3.

### 6.4 Penulis lama yang harus ikut berubah

Satu-satunya tempat lain yang menulis skor langsung ke `session.games` adalah
importer v1 (`tools/import/main.nim:486-502`). Setelah P0, importer harus:

1. tetap menulis sesi tanpa `scoring_preset`/`scoring_rules` (default migrasi =
   `legacy_v1`, `pointsToWin` 30 — format yang memang dimainkan v1);
2. menulis satu baris `game_sets (set_no = 1)` setiap kali `score_a/score_b`
   terisi, di transaksi yang sama dengan upsert game.

Kalau langkah 2 terlewat, sesi hasil impor tidak terlihat oleh view: standings
dan rating akan kehilangan data tanpa error. Tambahkan test impor yang
menghitung `game_sets` = jumlah game berskor.

### 6.5 Kenapa bukan `game_sets` menempel ke `session.games.id`

Bisa, dan lebih sederhana. Tapi semua route dan modul sudah mengidentifikasi
game dengan `(round_no, court_no)` (game key), dan `putSchedule` melakukan
upsert berdasarkan pasangan itu. Memakai id akan memaksa setiap tulis skor
membaca id dulu dan menambah satu query. Kunci alami yang sudah dipakai
konsisten lebih murah, dengan FK komposit sebagai pengaman.

### 6.6 Batasan ukuran

- `maxPoints ≤ 99` karena `game_sets_score_range` dan `session.games.score_range`
  memakai 0..99. Total satu match maksimum 3 × 99 = 297, tetapi cap realistis
  saat ini 30 → maksimum 90.
- `set_no ≤ 9` memberi ruang untuk format panjang tanpa migrasi baru.
- Tidak ada batas jumlah pemain baru.

---

## 7. Engine aturan skor (modul murni)

Berkas baru: `modules/session/scoring.nim`. Tanpa DB, tanpa config loader,
supaya bisa diuji langsung dan dipakai ulang oleh route, rating, dan (secara
konsep) validasi klien.

### 7.1 Tipe

```nim
import std/[json, options]

type
  Side* = enum
    sdA = "a"
    sdB = "b"

  SetScore* = object
    a*: int
    b*: int

  ScoringMode* = enum
    smPreset = "preset"
    smLegacy = "legacy"

  ScoringRules* = object
    id*: string
    label*: string
    mode*: ScoringMode
    gamesToWin*: int
    pointsToWin*: int
    winBy*: int
    deuceAt*: Option[int]
    maxPoints*: int
    changeEndsAt*: Option[int]

  SetError* = enum
    seOk = "ok"
    seTie = "tie"
    seRange = "range"
    seTooFewPoints = "too_few_points"
    seAboveCap = "above_cap"
    seWinBy = "win_by"
    seTooManySets = "too_many_sets"
    seSetAfterEnd = "set_after_end"
    seNotContiguous = "not_contiguous"

  SetVerdict* = object
    error*: SetError
    setIndex*: int      # 1-based; 0 when the error is about the list
```

### 7.2 Validasi satu set

```nim
proc validSet*(rules: ScoringRules, s: SetScore): SetError =
  if s.a < 0 or s.b < 0 or s.a > 99 or s.b > 99:
    return seRange
  if s.a == s.b:
    return seTie
  if rules.mode == smLegacy:
    # v1 had no format rule: any non-tie in range was a valid game.
    return seOk
  let high = max(s.a, s.b)
  let low = min(s.a, s.b)
  if high > rules.maxPoints:
    return seAboveCap
  if high < rules.pointsToWin:
    return seTooFewPoints
  if high == rules.maxPoints:
    # Cap reached: a one-point lead wins, even if winBy is 2.
    return seOk
  let need = if rules.deuceAt.isSome and low >= rules.deuceAt.get:
               rules.winBy
             else:
               1
  if high - low < need: seWinBy else: seOk
```

Tabel kebenaran (dipakai sebagai test):

| Preset | Skor | Hasil | Alasan |
|---|---|---|---|
| majadu30 | 30–29 | sah | cap 30 |
| majadu30 | 29–28 | ditolak | belum 30 |
| majadu30 | 30–0 | sah | cap |
| classic21 | 21–19 | sah | 21 poin, selisih 2 |
| classic21 | 21–20 | ditolak | deuce 20–20 butuh 2 |
| classic21 | 22–20 | sah | deuce terpenuhi |
| classic21 | 30–29 | sah | cap |
| classic21 | 31–29 | ditolak | di atas cap |
| classic21 | 29–28 | ditolak | deuce, selisih 1 |
| classic21 | 20–18 | ditolak | belum 21 |
| bwf15 | 15–13 | sah | 15 poin |
| bwf15 | 15–14 | ditolak | deuce 14–14 butuh 2 |
| bwf15 | 16–14 | sah | deuce terpenuhi |
| bwf15 | 21–20 | sah | cap 21 |
| bwf15 | 20–19 | ditolak | deuce, selisih 1 |
| legacy_v1 | 21–19 | sah | mode legacy |
| legacy_v1 | 30–5 | sah | mode legacy |
| semua | 15–15 | ditolak | seri |

Perhatikan urutan aturan: cap diperiksa **sebelum** `winBy`. Tanpa urutan itu,
30–29 di classic21 akan ditolak karena deuce, padahal cap justru mengakhiri
deuce.

### 7.3 Validasi daftar set

```nim
proc validateSets*(rules: ScoringRules, sets: openArray[SetScore]): SetVerdict =
  if sets.len > 2 * rules.gamesToWin - 1:
    return SetVerdict(error: seTooManySets)
  var wonA, wonB = 0
  for index, s in sets:
    let single = validSet(rules, s)
    if single != seOk:
      return SetVerdict(error: single, setIndex: index + 1)
    if wonA >= rules.gamesToWin or wonB >= rules.gamesToWin:
      return SetVerdict(error: seSetAfterEnd, setIndex: index + 1)
    if s.a > s.b: inc wonA else: inc wonB
  SetVerdict(error: seOk)
```

`seNotContiguous` disediakan untuk masa depan (mis. edit set ke-2 saja), tetapi
tidak dipakai di API v1 karena body selalu mengirim daftar penuh.

### 7.4 Turunan

```nim
proc setsWon*(rules: ScoringRules, sets: openArray[SetScore]): (int, int)
proc matchComplete*(rules: ScoringRules, sets: openArray[SetScore]): bool
proc winnerSide*(rules: ScoringRules, sets: openArray[SetScore]): Option[Side]
proc points*(sets: openArray[SetScore]): (int, int)
```

`matchComplete` = `setsWon[0] >= gamesToWin or setsWon[1] >= gamesToWin`.

### 7.5 Margin untuk rating

```nim
proc ratingMargin*(rules: ScoringRules, sets: openArray[SetScore]): float =
  ## Average margin per set, relative to the game's target:
  ##
  ##   r = sum(a - b) / (pointsToWin * setsPlayed)
  ##
  ## The caller feeds `r * pointsToWin` into
  ## gameValue(base, margin, target = pointsToWin), so the result is
  ##   base * (0.5 + 0.5 * clamp(r, -1, 1)).
  ##
  ## For a single set this is exactly the v1 formula with target 30, which is
  ## the format legacy sessions were played in.
  if sets.len == 0 or rules.pointsToWin <= 0:
    return 0.0
  var total = 0
  for s in sets:
    total += s.a - s.b
  total.float / (rules.pointsToWin.float * sets.len.float)
```

Tidak ada field target terpisah: `pointsToWin` dari snapshot adalah target
penilaian. Sesi lama memakai 30 karena memang MAJADU 30; sesi baru memakai
target presetnya. `rating.score_target` hanya tersisa sebagai fallback untuk
baris tanpa snapshot (lihat §10.5).

### 7.6 Serialisasi

```nim
proc parseRules*(node: JsonNode): ScoringRules
proc rulesJson*(rules: ScoringRules): JsonNode
proc parsePresets*(node: JsonNode): seq[ScoringRules]
```

`parseRules` dipakai untuk config dan untuk membaca snapshot dari DB. Bentuk
keduanya identik; tidak ada default yang hanya berlaku di satu jalur.

### 7.7 Salinan di klien

`apps/web/src/legacy/utils/scoreValidation.ts` sekarang hanya mengecek seri dan
0..99. Ganti dengan fungsi yang menerima `scoring` dari respons sesi dan
mengimplementasikan aturan yang sama. Ini **pratinjau**, bukan otoritas:
server tetap memvalidasi ulang dan mengembalikan kode error.

Alasan menyalin, bukan memanggil server per set: operator mengetik tiga set
berurutan; round-trip per set membuat input terasa rusak saat jaringan lambat.
Test klien harus memakai tabel kebenaran yang sama dengan engine Nim (lihat
§16) supaya dua implementasi tidak menyimpang.

---

## 8. Alur tulis & alur baca

### 8.1 Membuat sesi

`POST /c/{slug}/sessions` menerima field opsional `scoringPreset`.

Urutan di `createSession` (`apps/api/src/app.nim:~575`):

1. Baca `scoringPreset`; kalau bukan string → `400 INVALID_BODY`.
2. Ambil snapshot config + settings komunitas (`currentSettings`).
3. Tentukan id: field → atau `stringValue(settings, keySessionDefaultScoringPreset)`.
4. Cari preset di `session.scoring_presets`; tidak ada → `400 INVALID_PRESET`.
   `legacy_v1` juga ditolak di sini.
5. Susun `scoring_rules` dari preset (tanpa field target terpisah).
6. Insert sesi dengan kedua kolom.

Sesi lama tidak pernah melewati jalur ini; kolomnya sudah terisi default migrasi.

### 8.2 Mengubah preset

`PATCH /c/{slug}/sessions/{id}` menerima `scoringPreset`.

Guard (di `modules/session/write.nim`):

```
if patch.scoringPreset.isSome:
  session harus status 'draft'           -> 409 LOCKED
  tidak boleh ada baris session.game_sets -> 409 PRESET_LOCKED
  id harus ada di config saat ini         -> 400 INVALID_PRESET
  snapshot diganti penuh (bukan merge)
```

Snapshot diganti, bukan ditambal, supaya aturan sesi selalu konsisten dengan
preset yang dipilih.

"Belum ada set" berarti operator harus mengosongkan set dulu:
`PATCH .../games/{key}` dengan `{"sets": []}` menghapus semua set dan
mengembalikan status game ke `scheduled`. Tidak ada endpoint baru.

### 8.3 Menulis skor

`PATCH /c/{slug}/sessions/{id}/games/{gameKey}` (tetap, dengan `If-Match`):

Body baru:

```json
{
  "sets": [
    {"a": 21, "b": 18},
    {"a": 19, "b": 21},
    {"a": 21, "b": 17}
  ]
}
```

Body lama tetap diterima:

```json
{"scoreA": 30, "scoreB": 28}
```

Aturan kompatibilitas:

| Preset sesi | Body `scoreA/scoreB` | Body `sets` |
|---|---|---|
| `gamesToWin = 1` (termasuk legacy) | diterima → satu set | diterima, maksimal 1 set |
| `gamesToWin > 1` | `400 SETS_REQUIRED` | diterima |

`scoreA/scoreB` untuk sesi multi-set tidak "ditebak" jadi set pertama. Menebak
akan membuat match 1–0 yang tidak pernah dimainkan.

Alur tulis (`setSets` di `schedule.nim`, pengganti `setScore`):

```
1. parseGameKey
2. gate(): draft + versi cocok                -> 404/409
3. baca scoring_rules sesi
4. validSet untuk tiap set                    -> 400 INVALID_SCORE (index)
5. validateSets (jumlah, urutan, setelah end) -> 400 INVALID_SET_SEQUENCE
6. bump() versi sesi
7. delete from session.game_sets where ...
8. insert semua set
9. update session.games set status = 'played' | 'scheduled'
   - played bila matchComplete
   - scheduled bila parsial atau kosong
10. commit
```

Catatan status: kalau match sebelumnya ditandai `played` tanpa set, lalu diisi
satu set parsial, status kembali ke `scheduled` sampai match benar-benar
selesai. `played` berarti "terjadi dan lengkap" untuk keperluan hitung; penanda
"terjadi tanpa skor" hanya berlaku selama belum ada set.

Semua langkah 6–9 dalam satu transaksi, jadi tidak ada keadaan "set tersimpan
tapi status salah" kalau proses mati di tengah.

Set kosong (`{"sets": []}`) berarti hapus skor: set dihapus, status `scheduled`.
Ini juga cara membatalkan match yang salah input.

Status game **tidak** ditambah `in_progress`. Tiga nilai lama
(`scheduled`/`played`/`cancelled`) cukup; progres dibaca dari panjang `sets`.
Menambah nilai status akan memaksa perubahan constraint, kontrak, dan semua
konsumen yang membandingkan string.

### 8.4 `setPlayed`

Perilaku lama: `{"played": true}` menandai game terjadi tanpa skor;
`{"played": false}` mengembalikan ke `scheduled` dan menghapus skor.

Perilaku baru:

| Body | Ada set? | Efek |
|---|---|---|
| `{"played": true}` | tidak | status `played`, tanpa set (sama seperti v1) |
| `{"played": true}` | ya | `409 MATCH_HAS_SETS` — minta clear dulu |
| `{"played": false}` | tidak | status `scheduled` |
| `{"played": false}` | ya | set dihapus, status `scheduled` |

Alasan `true` + set ditolak: menandai "played" pada match berset akan menghapus
set yang sudah diisi, dan itu tidak boleh terjadi karena klik yang tidak
sengaja. Tujuan "played tanpa skor" hanya masuk akal sebelum ada set.

### 8.5 Swap

`modules/session/swap.nim` memindahkan isi satu game ke game lain (termasuk
pemain dan skor) selama sesi draft. Dengan set:

- `readContent` ikut membaca `game_sets` untuk (round, court);
- `writeContent` memindahkan set ke target;
- `score_a/score_b` tetap disalin apa adanya (untuk sesi legacy yang masih
  menyimpannya), meskipun baris baru selalu `null`.

Urutan di dalam transaksi: baca kedua sisi → hapus set di kedua slot → tulis
set ke target. Unique `(session_id, round_no, court_no, set_no)` aman karena
penghapusan terjadi sebelum insert.

Test wajib: swap game BO3 2–1 ke slot kosong mempertahankan tiga set dan
pemenang; swap balik mengembalikan keadaan semula.

### 8.6 Hapus sesi

`session.game_sets` memakai `on delete cascade` ke `session.games`, dan
`session.games` cascade ke `session.sessions`. `delete` di `write.nim` sudah
menghapus `session.games`; set ikut tanpa perubahan kode. Test yang ada harus
tetap lulus.

### 8.7 Membaca sesi

`GET /c/{slug}/sessions/{id}`:

```json
{
  "id": "...",
  "title": "SUNDAY FUNDAY",
  "date": "2026-11-01",
  "scoring": {
    "preset": "classic21",
    "label": "Classic BO3 21",
    "gamesToWin": 2,
    "pointsToWin": 21,
    "winBy": 2,
    "deuceAt": 20,
    "maxPoints": 30,
    "changeEndsAt": 11
  },
  "games": [
    {
      "round": 1,
      "court": 1,
      "sideA": ["..."],
      "sideB": ["..."],
      "scoreA": 61,
      "scoreB": 58,
      "setsWonA": 2,
      "setsWonB": 1,
      "winner": "A",
      "sets": [
        {"set": 1, "a": 19, "b": 21},
        {"set": 2, "a": 21, "b": 18},
        {"set": 3, "a": 21, "b": 19}
      ],
      "status": "played"
    }
  ]
}
```

Aturan payload:

- `scoreA/scoreB` = total poin semua set (bukan set yang dimenangkan). Nama
  dipertahankan supaya konsumen lama tidak pecah; arti barunya didokumentasikan.
- `setsWonA/setsWonB` = jumlah set.
- `winner` = `"A"`, `"B"`, atau `null`. Untuk match parsial `null`.
- `sets` selalu ada (array kosong untuk game tanpa skor).
- `scoring` hanya di detail dan share, **tidak** di respons create/patch/lock,
  supaya diff parity lebih kecil dan klien memang selalu membaca detail setelah
  navigasi.

`GET /c/{slug}/sessions/{id}/games/{gameKey}` mengembalikan bentuk game yang
sama (tanpa `scoring`), untuk konsumen yang membaca satu game.

`GET /s/{code}` memakai bentuk game yang sama + `scoring` di level atas.

### 8.8 Membaca standings

`sessionStandings.compute` tetap mengembalikan bentuk yang sama
(`items[].wins/losses/pointsFor/pointsAgainst/diff`). Yang berubah hanya query:

```sql
select round_no, court_no, winner, points_a, points_b, status
from session.game_results
where community_id = $1 and session_id = $2
  and status = 'played' and winner <> ''
```

Perhitungan:

- sisi A menang bila `winner = 'a'`;
- `pointsFor` = `points_a` atau `points_b` sesuai sisi;
- satu match menambah **satu** menang/kalah.

Tidak perlu mengubah sorting atau bentuk JSON.

---

## 9. API & kontrak

### 9.1 Ringkasan perubahan

| Operasi | Perubahan | Kode error baru |
|---|---|---|
| `POST /c/{slug}/sessions` | field `scoringPreset` opsional | `400 INVALID_PRESET` |
| `PATCH /c/{slug}/sessions/{id}` | field `scoringPreset` opsional, guard set | `409 PRESET_LOCKED`, `400 INVALID_PRESET` |
| `PATCH .../games/{gameKey}` | body `sets[]`; `scoreA/scoreB` hanya single-set | `400 SETS_REQUIRED`, `400 INVALID_SET_SEQUENCE`, `409 MATCH_HAS_SETS` |
| `GET .../sessions/{id}` | `scoring`, `sets`, `setsWonA/B`, `winner` | — |
| `GET .../sessions/{id}/games/{gameKey}` | bentuk game baru | — |
| `GET /s/{code}` | `scoring` + bentuk game baru | — |
| `GET .../standings` | tidak berubah | — |
| `GET /c/{slug}/config` | field read-only `scoringPresets` | — |
| `PATCH /c/{slug}/settings` | validasi `session.default_scoring_preset` | `400 INVALID_CONFIG` |

`400 INVALID_SCORE` yang lama tetap dipakai; pesannya menyebut nomor set
(`set 2: win by 2`).

### 9.2 Kontrak OpenAPI

`packages/contracts/openapi/core.yaml` dan `community.yaml` tidak
mendefinisikan schema body. Jadi:

- tidak ada perubahan `operationId`, path, atau jumlah operasi (tetap 75);
- perubahan hanya di deskripsi request/response;
- `packages/web-client/src/api.ts` dan `apps/api/src/routes_gen.nim` **tidak
  berubah**, dibuktikan oleh fingerprint `CONTRACT.sha256`.

Yang didokumentasikan:

1. `createSession` — field `scoringPreset`, default dari
   `session.default_scoring_preset`, daftar id dari `session.scoring_presets`.
2. `patchSession` — field sama + syarat "no sets recorded yet".
3. `patchGame` — dua bentuk body, kode error, dan arti `scoreA/scoreB` sebagai
   total poin.
4. `getSession` / `getGame` / `getShared` — field baru.
5. Semua tetap menyebut `429`, `413`, `If-Match`, `ETag` seperti sekarang.
6. `getCommunityConfig` — field `scoringPresets`; `patchSettings` — validasi id
   default preset.

Regenerasi: `./task contract-gen && ./task contract-check`.

### 9.3 Parity

Korpus `testdata/parity/v2` berisi 34 case terkait sesi. Yang berubah body-nya:

- `get_session*`, `get_shared*`, `get_game*` (field baru);
- `create_session`, `patch_session*`, `lock_session*` **tidak** berubah karena
  `scoring` tidak ditambahkan ke respons tulis.

Rencana: re-record case detail/share/game setelah P0, dan re-record case
rating/papan karena target berubah 21 → 30 (§11.A). Case `v1` golden corpus
tetap harus lulus; yang berubah hanya korpus v2 milik repo ini. Rekam dengan
perintah yang ada di `task.d/parity*.sh`; jangan menyunting JSON dengan tangan.

---

## 10. Dampak ke perhitungan poin (rating)

### 10.1 Rumus yang berlaku

Satu match menyumbang satu nilai:

```
r    = Σ(a_s − b_s) / (pointsToWin × setsPlayed)       # rata-rata margin per set
v    = sessionBase × (0.5 + 0.5 × clamp(r, −1, 1))
poin = v × opponentMultiplier
```

Lalu entry satu sesi = jumlah semua nilai match, dan papan mengambil
`best_n` entry dalam `window_weeks`.

Yang **tidak** berubah:

- `sessionBase` (250), `opponent_clamp` (0.5..1.5), `window_weeks` (12),
  `best_n` (10), `thin_evidence_n` (3), `tier_bands`.
- `opponentMultiplier` dihitung per match dari tier lawan, bukan per set.
- Jumlah entry: satu sesi tetap satu entry, berapa pun jumlah set atau match.
- `player_state`: satu match menambah satu `games_played` dan satu win/loss.

### 10.2 Sifat penting: antisimetri

`v(+r) + v(−r) = sessionBase` selama tidak kena clamp. Artinya poin yang
diberikan ke pemenang dan lawannya selalu berjumlah 250 (sebelum multiplier).
Ini sudah benar hari ini dan tetap benar setelah perubahan.

Yang berubah adalah **sebarannya**:

- Sebelumnya target 21 pada game 30 poin membuat margin 25 (30–5) kena clamp →
  pemenang 250, lawan 0.
- Sekarang target 30 membuat margin 25 menjadi `r = 0.833` → 229.17 dan 20.83.

Jadi blowout berhenti memberi hadiah penuh. Karena poin dihitung ulang saat
dibaca, perbaikan ini berlaku untuk sesi lama juga.

### 10.3 Satu skala, tiga format

| Data | Target | Contoh 30–28 | Contoh 30–5 |
|---|---|---|---|
| Sesi lama (MAJADU 30) | 30 | 133.33 | 229.17 |
| Sesi baru MAJADU 30 | 30 | 133.33 | 229.17 |
| Sesi baru Classic 21 | 21 | — (skor 21) | — |
| Sesi baru BWF 15 | 15 | — (skor 15) | — |

Konsekuensi yang harus disadari:

- **Papan lama bergerak.** Pemain yang poinnya banyak datang dari blowout
  kehilangan sebagian; pemain yang kalah tipis mendapat lebih banyak.
- Total poin satu match tetap 250, jadi total komunitas tidak membengkak atau
  menyusut; hanya distribusinya yang berubah.
- Snapshot harian (`rating.snapshots`) yang tersimpan masih berisi angka lama.
  `prevRank`/`rankDelta` bisa menunjukkan pergerakan sekali saat rilis. Badge
  `rank_streak` yang sudah ada **tidak** dihitung ulang (lihat §17).
- Tidak ada migrasi poin: `rating.events` tidak menyimpan poin, jadi cukup
  deploy dan papan langsung memakai target baru.

### 10.4 Kenapa rata-rata per set, bukan total

Kalau memakai total poin mentah:

- BO3 otomatis bernilai sampai 3× satu game (42–63 poin vs 30);
- pemenang 2–0 selalu mengalahkan pemenang 2–1 hanya karena main lebih sedikit
  set;
- cap dan deuce tidak punya arti di poin.

Dengan rata-rata per set:

- pemenang 2–0 dan 2–1 dengan dominasi sama bernilai sama;
- menarik match ke tiga set tidak menambah poin;
- kemenangan deuce panjang (30–29, 30–29) justru bernilai lebih kecil daripada
  kemenangan normal (21–15, 21–15), karena rasionya mengukur dominasi, bukan
  ketahanan. Ini perilaku yang sudah ada di v1 untuk game tunggal.

### 10.5 Efek ke pembaca poin

| Pembaca | Perubahan |
|---|---|
| `projection.sessionEntries` | JOIN ke `session.game_results`; `target = points_to_win` per baris; `margin = ratingMargin × target` |
| `read.boardRows` | tidak berubah (memakai proyeksi) |
| `read.playerHistory` | pakai `points_a/points_b` dan tambahkan `sets` |
| `read` lawan/partner tersering | pakai view, hitung per match |
| `ingest` | menang/kalah dari `winner`; tidak menghitung poin |
| `achievement` | `games`/`wins` per match |
| `snapshots` | tidak berubah; `rating` = poin papan hari itu |

Implementasi proyeksi tidak perlu membaca `game_sets` satu per satu: view sudah
memberi `points_a`, `points_b`, dan `sets_played`, dan `Σ(a−b) = points_a −
points_b`. Jadi cukup:

```
r = (points_a - points_b) / (points_to_win * max(sets_played, 1))
value = gameValue(base, r * points_to_win, points_to_win)
```

`ratingMargin` di engine tetap dipakai untuk unit test dan pratinjau UI, dengan
hasil yang sama.

`rating.score_target` tetap ada di registry sebagai **fallback** kalau sebuah
baris tidak punya `scoring_rules` (tidak mungkin setelah migrasi, tetapi
menghindari `null` yang membuat satu sesi hilang dari papan). Query memakai:

```sql
coalesce((s.scoring_rules->>'pointsToWin')::int, $4::int) as target
```

dengan `$4 = rating.score_target` (migrasi menaikkannya ke 30). Setelah dua
rilis key ini bisa dihapus; tidak ada lagi sesi yang dinilai dengan 21 kecuali
preset Classic 21.
Override komunitas pada `rating.score_target` tidak lagi memengaruhi sesi —
nilainya hanya dipakai kalau snapshot benar-benar tidak ada.

### 10.6 Turnamen tidak terpengaruh

`tournamentEntries` sudah memakai target per fase (`classicTarget`,
`teamTarget` di `modules/rating/infrastructure/tournament.nim`). Tidak ada
perubahan di sana. Turnamen tetap di luar lingkup fitur.

---

## 11. Simulasi angka

Semua contoh memakai `sessionBase = 250`, `opponentMultiplier = 1.0` kecuali
disebut lain. Pembulatan ke integer hanya terjadi saat total entry dilaporkan.

### 11.A Sesi lama: sebelum vs sesudah

Sesi lama (snapshot `legacy_v1`), tiga game. Sebelumnya dinilai dengan target 21;
sekarang target 30:

| Game | Skor | r (21) | Nilai (21) | r (30) | Nilai (30) |
|---|---|---|---|---|---|
| 1 | 30–28 | 0.095238 | 136.90 | 0.066667 | 133.33 |
| 2 | 30–25 | 0.238095 | 154.76 | 0.166667 | 145.83 |
| 3 | 28–30 | −0.095238 | 113.10 | −0.066667 | 116.67 |
| **Total** | | | **404.76** | | **395.83** |

Perubahan: −8,93 poin (−2,2%) untuk pemain ini. Lawan-lawannya mendapat
kenaikan yang sama besar, karena setiap match tetap berjumlah 250.

Contoh per match:

- 30–28: pemenang 136.90 → 133.33 (−3.57), lawan 113.10 → 116.67 (+3.57);
- 30–5: pemenang 250.00 → 229.17 (−20.83), lawan 0.00 → 20.83 (+20.83).

Jadi papan bergerak dari pemain yang menang besar ke pemain yang kalah tipis.
Tidak ada migrasi data; perubahan terjadi saat papan dibaca.

### 11.B Sesi baru MAJADU 30

Sesi baru memakai snapshot `majadu30` dengan `pointsToWin = 30`, jadi angkanya
sama persis dengan kolom "30" di §11.A. Tidak ada era kedua: sesi lama dan baru
untuk format yang sama kini dinilai dengan skala yang sama.

### 11.C Blowout

| Skor | Sebelum (target 21) | Sesudah (target 30) |
|---|---|---|
| 30–5 (pemenang) | 250.00 (clamp) | 229.17 |
| 5–30 (lawan) | 0.00 (clamp) | 20.83 |
| Jumlah | 250.00 | 250.00 |

Hadiah untuk menang besar turun 20,83 poin, dan lawan tidak lagi mendapat nol.
Pemain yang seluruh sesinya blowout kehilangan sekitar 8% poin; lawannya
mendapat kenaikan setara. Ini berlaku untuk sesi lama maupun baru.

### 11.D Normalisasi BO3

Classic BO3 21:

| Set | Σ margin | S | r | Nilai |
|---|---|---|---|---|
| 21–19, 21–19 | 4 | 2 | 0.095238 | 136.90 |
| 21–19, 19–21, 21–19 | 2 | 3 | 0.031746 | 128.97 |
| 21–18, 21–18 | 6 | 2 | 0.142857 | 142.86 |
| 21–18, 18–21, 21–18 | 3 | 3 | 0.047619 | 130.95 |
| 21–15, 21–15 | 12 | 2 | 0.285714 | 160.71 |
| 30–29, 30–29 | 2 | 2 | 0.047619 | 130.95 |
| 21–0, 21–0 | 42 | 2 | 1.000000 | 250.00 |

BWF 15:

| Set | Σ margin | S | r | Nilai |
|---|---|---|---|---|
| 15–13, 15–13 | 4 | 2 | 0.133333 | 141.67 |
| 15–10, 15–10 | 10 | 2 | 0.333333 | 166.67 |
| 21–19, 21–19 (cap) | 4 | 2 | 0.133333 | 141.67 |
| 15–0, 15–0 | 30 | 2 | 1.000000 | 250.00 |

Dua hal yang perlu disadari:

1. **Menang 2–0 tidak dua kali menang 1–0.** 21–18, 21–18 (142.86) sama dengan
   satu set 21–18 (r = 3/21 = 0.142857). Itu memang tujuannya: format tidak
   memberi bonus hanya karena ada set kedua.
2. **Menang deuce panjang bernilai lebih kecil.** 30–29, 30–29 (130.95) di bawah
   21–19, 21–19 (136.90), karena rasionya mengukur dominasi. Ini konsisten
   dengan rumus v1 dan perlu dikomunikasikan kalau ada yang bertanya.

### 11.E Perbandingan antar-preset pada dominasi setara

| Preset | Skor | r | Nilai |
|---|---|---|---|
| MAJADU 30 | 30–21 (margin 9 = 30% target) | 0.30 | 162.50 |
| Classic 21 | 21–15, 21–15 (margin 6 = 28,6%) | 0.285714 | 160.71 |
| BWF 15 | 15–11, 15–11 (margin 4 = 26,7%) | 0.266667 | 158.33 |

Selisih antar-preset di bawah 5 poin untuk dominasi yang sebanding. Ini bukti
bahwa normalisasi bekerja: pilihan format tidak menjadi cara curang menaikkan
poin.

### 11.F Simulasi satu sesi penuh

Sesi `classic21`, 4 pemain, 3 match, satu lapangan:

| Match | Sisi | Skor set | Set | Poin |
|---|---|---|---|---|
| 1 | A+B vs C+D | 21–18, 21–19 | 2–0 | 42–37 |
| 2 | A+C vs B+D | 19–21, 21–18, 21–19 | 2–1 | 61–58 |
| 3 | A+D vs B+C | 21–15, 21–17 | 2–0 | 42–32 |

Nilai match:

| Match | Σ margin | S | r | Menang | Kalah |
|---|---|---|---|---|---|
| 1 | 5 | 2 | 0.119048 | 139.88 | 110.12 |
| 2 | 3 | 3 | 0.047619 | 130.95 | 119.05 |
| 3 | 10 | 2 | 0.238095 | 154.76 | 95.24 |

Entry sesi per pemain (satu entry, dijumlahkan):

| Pemain | Match | Nilai | Total entry |
|---|---|---|---|
| A | M1 W, M2 W, M3 W | 139.88 + 130.95 + 154.76 | **425.59 → 426** |
| B | M1 W, M2 L, M3 L | 139.88 + 119.05 + 95.24 | **354.17 → 354** |
| C | M1 L, M2 W, M3 L | 110.12 + 130.95 + 95.24 | **336.31 → 336** |
| D | M1 L, M2 L, M3 W | 110.12 + 119.05 + 154.76 | **383.93 → 384** |

Standings sesi yang sama (satu match = satu menang/kalah):

| Peringkat | Pemain | W–L | PF | PA | Diff |
|---|---|---|---|---|---|
| 1 | A | 3–0 | 145 | 127 | +18 |
| 2 | D | 1–2 | 137 | 135 | +2 |
| 3 | B | 1–2 | 132 | 140 | −8 |
| 4 | C | 1–2 | 130 | 142 | −12 |

Perhatikan D di atas B dan C meski sama-sama 1–2: tie-break diff. Ini tetap
konsisten dengan aturan lama.

### 11.G Set parsial tidak dihitung

Kalau match 2 baru diisi dua set (19–21, 21–18), maka:

- `winner = ''`, `sets_played = 2`;
- match 2 tidak masuk standings dan tidak masuk rating;
- entry A sementara = 139.88 + 154.76 = 294.64 (dua match), lalu menjadi 425.59
  setelah set ketiga diisi.

Tidak ada "poin sementara" yang perlu di-rollback. Setelah match selesai,
`ingest`/proyeksi berikutnya memakai angka final.

### 11.H Multiplier lawan

Kalau rata-rata kekuatan tier lawan 1,2× populasi:

- match 1 untuk A/B: 139.88 × 1.2 = 167.86;
- match 1 untuk C/D: 110.12 × 1.2 = 132.14.

Jumlah tetap 300 (250 × 1.2). Perubahan format tidak menyentuh multiplier.

### 11.I best-N dan window

Pemain dengan 12 sesi dalam 12 minggu: tetap dihitung 10 entry terbaik. Sesi
BO3 tetap **satu** entry meskipun berisi tiga match. Jadi berpindah format
tidak menambah atau mengurangi jumlah entry yang bersaing di papan; hanya nilai
per entry yang berubah.

### 11.J Achievement

| Metrik | Perubahan |
|---|---|
| `games:*` | satu match BO3 = 1 game (bukan 3) |
| `wins:*` | satu match BO3 = 1 win |
| `sessions:*` | tidak berubah |
| `rank:*`, `rank_streak:*` | tidak berubah (snapshot) |
| `partners/opponents` | dihitung per match, bukan per set |

Contoh: pemain dengan 12 match Classic 21 mendapat badge `games:10` pada match
ke-10, sama seperti 12 match MAJADU 30.

---

## 12. Standings

### 12.1 Perubahan minimal

`modules/session/standings.nim` hanya mengganti query game dan sumber
menang/kalah:

```nim
for game in db.query("""
  select round_no, court_no, winner, points_a, points_b
  from session.game_results
  where community_id = $1::uuid and session_id = $2::uuid
    and status = 'played' and winner <> ''
  order by round_no, court_no""", ...):
  ...
  let aWon = game.get("winner") == "a"
```

Aturan absen dan skip tetap:

- sisi yang semua pemainnya absen → match dibuang;
- pemain yang di-skip tidak dihitung, sisi lain tetap dapat hasil;
- kalau kedua sisi kosong setelah skip → match dibuang.

Yang berubah hanya satu baris: `scoreA > scoreB` menjadi `winner = 'a'`, dan
`pointsFor/Against` memakai total poin match.

### 12.2 Tie-break

Tetap: wins → diff → pointsFor → nama. Tidak ada perubahan.

Catatan: `diff` dalam satu sesi BO3 memakai total poin 3 set (mis. +18), jadi
angkanya lebih besar daripada sesi single game. Itu tidak masalah karena
standings selalu per sesi, tidak pernah menggabungkan dua format.

Kalau suatu saat ada "standings musiman" lintas sesi, ia harus memakai poin
rating, bukan `pointsFor` mentah. Itu sudah menjadi arah desain sekarang.

### 12.3 Tampilan

`GET .../standings` **tidak berubah bentuk** — parity aman. Detail set tidak
dimasukkan ke standings karena satu baris standings adalah satu pemain, bukan
satu match. Detail set ada di `games` pada detail sesi/share.

Di UI, tab Standings tetap seperti sekarang. Yang ditambah hanya kolom kecil
"set" di kartu match (bukan di tabel standings), mis. `2–1` dengan rincian di
bawahnya.

### 12.4 Absen & skip pada match BO3

Contoh: A+B vs C+D, skor 2–1, tetapi B tercatat skip di match itu.

- A tetap mendapat win dan total poin sisi A;
- B tidak mendapat apa pun;
- C dan D mendapat loss dan total poin sisi B.

Ini sama dengan perilaku satu game sekarang. Tidak ada aturan baru per set,
karena skip selalu berlaku untuk seluruh match.

---

## 13. Achievement, share, export

### 13.1 Achievement

`modules/achievement/infrastructure/backfill.nim` mengganti query game menjadi
view dan memakai `winner`:

```nim
let aWon = row.get("winner") == "a"
```

Tidak ada perubahan pada katalog badge atau threshold. Yang perlu diuji:

- 10 match BO3 → `games:10`, bukan `games:25`;
- menang 2–0 dan 2–1 sama-sama satu win;
- rebuild setelah mengubah set menghitung ulang dengan benar.

### 13.2 Share (`GET /s/{code}`)

Tambahan:

```json
{
  "session": {"id": "...", "title": "...", "date": "...", "status": "..."},
  "scoring": {
    "preset": "classic21",
    "label": "Classic BO3 21",
    "gamesToWin": 2,
    "pointsToWin": 21,
    "winBy": 2,
    "deuceAt": 20,
    "maxPoints": 30
  },
  "games": [
    {
      "round": 1, "court": 1,
      "sideA": ["A", "B"], "sideB": ["C", "D"],
      "scoreA": 61, "scoreB": 58,
      "setsWonA": 2, "setsWonB": 1,
      "winner": "A",
      "sets": [
        {"set": 1, "a": 19, "b": 21},
        {"set": 2, "a": 21, "b": 18},
        {"set": 3, "a": 21, "b": 19}
      ],
      "status": "played"
    }
  ],
  "standings": {"items": [...]}
}
```

`standings` tetap dari server (`sessionStandings.compute`), jadi halaman publik
dan halaman member tidak bisa berbeda.

### 13.3 Export Instagram

`InstagramPostPage` memakai `computeStandings` di klien dari `CloudSnapshot`.
Setelah perubahan:

- `computeStandings` menerima `setsWonA/setsWonB` (atau `winner`) dan total
  poin; kalau field baru tidak ada (data lama di cache), fallback ke
  `scoreA/scoreB`;
- `canvasPost.ts` yang menentukan pemenang dari perbandingan skor
  (`row.scoreA > row.scoreB`) harus memakai `winner`/`setsWon`, kalau tidak
  kartu hasil bisa menandai pemenang yang salah pada match 2–1;
- tabel top-10 tidak berubah;
- kartu hasil menampilkan `2–1` besar dan `21–18, 19–21, 21–17` kecil;
- untuk `gamesToWin = 1`, tampilan tetap `30–28` supaya tidak ada noise.

Batas canvas 1080×1350 sudah cukup: satu baris rincian set memakai font 11–12
px dan maksimal ~90 karakter. Kalau lebih panjang (mis. 30–29, 29–30, 30–29),
tetap muat; tidak perlu mengubah ukuran canvas.

`PREVIEW`/story memakai `STORY_WIDTH/STORY_HEIGHT` dari
`legacy/config/canvas.ts` (sudah disatukan di `d16a3ad`), tidak ada angka baru.

### 13.4 Scoreboard

`ScoreboardPage` membaca sesi yang sama. Kalau ia menampilkan skor, pakai
`setsWonA/setsWonB` + `sets`; tidak ada endpoint baru.

---

## 14. UI

### 14.1 Wizard (`apps/web/src/legacy/pages/SetupPage.tsx`)

Kartu baru "Format skor" di langkah 1, di atas Courts:

```
Format skor
( ) MAJADU 30        Single game · 30 poin · tanpa deuce
(•) Classic BO3 21   Best of 3 · 21 poin · deuce 20–20 · cap 30
( ) New BWF BO3 15   Best of 3 · 15 poin · deuce 14–14 · cap 21
```

Perilaku:

- Default = `session.default_scoring_preset` dari `effective` config yang sudah
  dibaca halaman (community scope); daftar opsi dari field `scoringPresets`
  pada respons config yang sama.
- Pilihan disimpan di state wizard dan dikirim sebagai `scoringPreset` saat
  create.
- Ringkasan aturan berupa satu baris teks, bukan tabel; operator tidak perlu
  membaca matriks.
- Tidak menambah langkah. Wizard tetap 4 langkah.
- Kalau config preset berubah saat wizard terbuka, id yang dipilih bisa hilang;
  create akan menjawab `400 INVALID_PRESET` dan UI menampilkan pesan "format
  tidak tersedia lagi, pilih ulang" serta memuat ulang daftar.
- Aksesibilitas: `fieldset`/`legend`, radio asli (bukan div), label terhubung,
  target sentuh ≥ 44 px, fokus terlihat.

### 14.2 Editor skor (`ScheduleGrid` + `useScoreDraft`)

State berubah dari `{a: string, b: string}` menjadi:

```ts
type SetDraft = { a: string; b: string }
type MatchDraft = { sets: SetDraft[] }
```

Alur:

1. Klik `+ score` → panel terbuka dengan satu baris per set.
2. Baris set bertambah otomatis saat set sebelumnya sah dan match belum selesai.
3. Set yang menentukan pemenang menutup input berikutnya.
4. Tombol simpan mengirim **seluruh** daftar set (bukan satu set).
5. Set kosong di tengah ditolak dengan pesan "set 2 is empty" (tidak dikirim
   sebagai 0–0).
6. `Clear` mengirim `{"sets": []}`.

Validasi klien memakai `scoring` dari sesi; server tetap otoritatif.

Pesan error server dipetakan:

| Kode | Pesan UI |
|---|---|
| `INVALID_SCORE` | "Set 2: win by 2 at 20–20" |
| `INVALID_SET_SEQUENCE` | "No more sets: the match is already won" |
| `SETS_REQUIRED` | "This format needs set scores" |
| `MATCH_HAS_SETS` | "Clear the sets before marking the match played" |
| `PRESET_LOCKED` | "Preset is locked once a set is recorded" |

### 14.3 Tampilan ringkas

`SlotGameCard` / `ScheduleGrid`:

- match selesai: `2–1` besar, `21–18 · 19–21 · 21–17` kecil;
- match parsial: `1–1` dengan `in progress` (bukan warna saja);
- single game: tetap `30–28`;
- jangan menampilkan total poin sebagai angka utama — total poin bisa
  menyesatkan (kalah total poin tapi menang match).

`PlayerMatchDetailSheet` menambahkan baris rincian set di bawah skor match.

### 14.4 Settings komunitas (`apps/web/src/pages/SettingsPage.tsx`)

`FIELDS` sekarang hanya mendukung `text`/`number`. Tambahkan `select`:

```ts
{ key: 'session.default_scoring_preset', label: 'community.setting.scoringPreset',
  kind: 'select', optionsFrom: 'scoringPresets' }
```

Opsi diambil dari `scoringPresets` pada respons
`GET /c/{slug}/config` (bukan dari `effective`), label dari `label` preset.
Simpan memakai `updateCommunityConfig` yang sudah ada; server memvalidasi id.

Tambahkan string i18n di `apps/web/src/i18n/en.ts`:

```
'community.setting.scoringPreset'
'setup.scoring.title'
'setup.scoring.hint'
'score.set'
'score.setsRequired'
'score.matchWon'
'score.clear'
```

### 14.5 Copywriting

- "Format skor" bukan "Scoring preset" di UI.
- Ringkasan memakai istilah pemain: "Best of 3", "deuce 20–20", "cap 30".
- Hindari "game" untuk set; di UI, "game" = match yang dimainkan.
- Tidak ada istilah teknis seperti `ratingTarget` di layar.

### 14.6 Loading & error state

- Wizard: daftar preset berasal dari config yang sudah dimuat halaman; tidak ada
  spinner tambahan.
- Editor: tombol simpan disabled selama request; error tampil di panel, tidak
  menutup panel.
- Share: kalau `scoring` tidak ada (cache lama), tampilkan skor saja tanpa
  rincian set — jangan menebak format.

---

## 15. Fase pengerjaan & kriteria terima

### P0 — Config, skema, engine, pembaca (1–2 hari)

Isi:

1. Registry + seed + migrasi `0029_scoring_presets.sql`.
2. `modules/session/scoring.nim` + unit test tabel kebenaran.
3. Backfill set dari skor lama.
4. View `session.game_results`.
5. Pindahkan **semua** pembaca ke view: standings, projection, ingest, read,
   achievement.
6. Detail sesi/share mengembalikan `sets`, `setsWonA/B`, `winner`, `scoring`.
7. `POST /sessions` menerima `scoringPreset` dan menyimpan snapshot
   (`legacy_v1` untuk data lama, preset untuk sesi baru).
8. `PATCH` skor masih menerima `scoreA/scoreB` (single-set) supaya UI lama
   tetap jalan; di baliknya `setScore` menulis satu baris `game_sets`
   (bukan `score_a/score_b`), sehingga view sudah menjadi satu-satunya
   sumber kebenaran sejak P0.
9. `GET /c/{slug}/config` mengembalikan `scoringPresets` read-only.
10. Importer v1 ikut menulis `game_sets` untuk skor lama (§6.4).

Kriteria terima:

- `./task check`, `./task verify session|rating|achievement|api` lulus.
- `./task parity v1 verify` tidak berubah.
- Perubahan papan sesuai §11.A: angka lama dihitung ulang dengan target 30;
  total per match tetap 250, tidak ada poin yang hilang.
- Snapshot harian lama tidak ditulis ulang; `prevRank`/`rankDelta` boleh
  menunjukkan pergerakan sekali saat deploy (didokumentasikan di §17).
- Setelah deploy, jalankan `./task ranksnapshot` agar baris snapshot hari itu
  memakai angka baru (upsert per tanggal, jadi aman diulang).
- Parity case detail/share/game di-rekam ulang; diff hanya field baru.
- Case config di-rekam ulang karena `scoringPresets`; tidak ada operasi baru.

Catatan: P0 sengaja belum menerima `sets` dari klien. Kalau ada bug di view,
UI lama masih bisa menulis skor tunggal dan tidak ada data baru yang rusak.

### P1 — Jalur tulis multi-set (1 hari)

Isi:

1. `setSets` menggantikan `setScore` (nama lama dipertahankan sebagai wrapper).
2. Body `sets[]`, validasi engine, `SETS_REQUIRED`, `INVALID_SET_SEQUENCE`.
3. `{"sets": []}` untuk menghapus.
4. `setPlayed` + `MATCH_HAS_SETS`.
5. `PATCH /sessions/{id}` menerima `scoringPreset` + guard `PRESET_LOCKED`.
6. Swap memindahkan set.
7. Kontrak diperbarui + regen.

Kriteria terima:

- Integration test: tulis 2 set parsial → tidak dihitung; set ketiga →
  `played`, standings/rating berubah.
- Preset tidak bisa diganti setelah ada set; setelah clear bisa.
- Swap BO3 mempertahankan set.
- Tidak ada jalur yang masih menulis `session.games.score_a/score_b`.

### P2 — UI (1–2 hari)

Isi:

1. Kartu format di wizard.
2. Editor set + validasi klien.
3. Tampilan ringkas + detail pemain.
4. Share page + export.
5. i18n.

Kriteria terima:

- E2E: buat sesi Classic 21, isi tiga match, cek standings dan share.
- Sesi MAJADU 30 tidak berubah tampilannya (regression visual).
- Keyboard-only bisa mengisi semua set; error terbaca screen reader.
- Tidak ada layout shift di kartu 1080×1350.

### P3 — Default komunitas + dokumentasi (½ hari)

Isi:

1. `select` di Settings.
2. Validasi route config.
3. Handbook: data model, config, alur skor.
4. `docs/DECISIONS.md` entri ADR.

Kriteria terima:

- Ganti default komunitas → wizard membuka dengan pilihan itu.
- Override ke id yang tidak ada → `400 INVALID_CONFIG`.
- Dokumentasi menjelaskan perubahan retroaktif ke target 30 dan alasan
  snapshot per sesi.

### P4 — Bersih-bersih (rilis berikutnya, bukan sekarang)

1. Drop `session.games.score_a/score_b` + `games_not_tied`.
2. Hapus `rating.score_target` setelah fallback tidak diperlukan.
3. Hapus wrapper `setScore` kalau tidak ada pemanggil.

Jangan dilakukan bersamaan dengan P0–P2: rollback butuh kolom lama.

### 15.1 Status implementasi (6 Nov 2026)

Sudah dikerjakan di working tree, belum di-commit:

- P0: registry + seed + migrasi `0029`, engine `modules/session/scoring.nim`
  (+ unit test), backfill set, view `session.game_results`, semua pembaca
  dipindah ke view, detail/game/share mengembalikan `sets`/`setsWonA/B`/
  `winner`/`scoring`, `POST /sessions` menerima `scoringPreset`, config
  mengembalikan `scoringPresets`, importer menulis `game_sets`.
- P1: `setSets`, body `sets[]`, `SETS_REQUIRED`, `INVALID_SET_SEQUENCE`,
  `MATCH_HAS_SETS`, `PRESET_LOCKED`, swap memindahkan set, `setPlayed`/`skip`
  membersihkan set, tidak ada lagi penulis `score_a/score_b` selain null.
- P2: kartu format di setup, editor set dengan validasi klien, tampilan ringkas
  `2–1` + rincian set, detail pemain, halaman share publik, standings memakai
  set. Export Instagram ikut memakai pemenang per set.
- P3 (sisi server + Settings): validasi default preset di config route, pilihan
  default di `SettingsPage`.

Diverifikasi: `./task check`, `./task verify session`, `./task verify rating`,
`./task verify achievement`, `./task verify api`, `./task parity v2 verify`,
`pnpm check:types`, `pnpm test` (103 tes). Belum bisa dijalankan di lingkungan
ini: bukti deploy VPS/Podman, baseline visual Linux, dan E2E browser penuh
(dev server dijalankan pemilik). `pnpm check:tailwind` gagal karena dua kelas
arbitrer lama di `ShareLinkPanel.tsx`/`AdminSessionsPage.tsx`, bukan dari
perubahan ini.

---

## 16. Rencana pengujian

### 16.1 Unit — `modules/session/tests/scoring_test.nim`

- Tabel kebenaran §7.2 untuk ketiga preset + legacy.
- `validateSets`: 0 set, 1 set, 2 set, 3 set, 4 set pada BO3.
- Set setelah match selesai → `seSetAfterEnd`.
- `setsWon`, `matchComplete`, `winnerSide` untuk 2–0, 2–1, 1–2, 1–1.
- `ratingMargin`: single set = margin/target; BO3 = rata-rata; legacy memakai
  target 30.
- `parsePresets`: id duplikat, `maxPoints` ≤ `pointsToWin`, `deuceAt` di luar
  rentang, `legacy_v1` ditolak.
- `parseSnapshotNode`: `pointsToWin` wajib ada dan > 0.
- Config: `rating.score_target` terbaca 30, `session.default_scoring_preset`
  menunjuk preset yang ada.

### 16.2 Integration — sesi

- `sets` parsial disimpan, status `scheduled`.
- Set ketiga menyelesaikan match → `played`.
- Set keempat setelah 2–1 ditolak.
- `scoreA/scoreB` pada sesi BO3 → `SETS_REQUIRED`.
- `scoreA/scoreB` pada sesi MAJADU 30 → satu set, perilaku lama.
- Dua penulis bersamaan → yang kedua `409` stale.
- Setelah lock → semua tulis `409` locked.
- `{"sets": []}` menghapus set dan membuka preset.
- `{"played": true}` pada match berset → `MATCH_HAS_SETS`.
- Swap memindahkan set; hapus sesi menghapus set.

### 16.3 Integration — rating & achievement

- Sesi lama: entry memakai target 30 (golden number §11.A), bukan 21.
- Sesi MAJADU 30 baru: 30–28 → 133.33 sebelum multiplier.
- Sesi Classic 21: 21–19, 21–19 → 136.90.
- Match parsial tidak menambah entry.
- Satu match BO3 menambah 1 game/1 win di `player_state`.
- `games:10` tercapai pada match ke-10, bukan set ke-10.
- Rebuild idempoten.
- Importer v1: jumlah `game_sets` = jumlah game berskor; sesi hasil impor
  memakai `legacy_v1` dan dinilai dengan target 30.

### 16.4 Parity

- Rekam ulang case `get_session*`, `get_game*`, `get_shared*`, dan config
  (`scoringPresets`).
- Pastikan case `create_session`, `patch_session*`, `lock_session*` **tidak**
  berubah (karena `scoring` tidak ada di respons tulis).
- Rekam ulang case rating/papan untuk data lama, karena target berubah 21 → 30
  (bandingkan dengan golden number §11.A).
- `./task parity v1 verify` tetap lulus.

### 16.5 E2E

- Wizard: pilih Classic 21 → sesi dibuat dengan format itu.
- Isi 3 set, lihat `2–1` dan rincian.
- Tab Standings: pemenang sesuai set, bukan total poin.
- Share page: format + rincian set tampil.
- Export: kartu Instagram memuat rincian set dan tidak overflow.
- MAJADU 30: alur lama tetap satu input.

### 16.6 Manual checklist

- [ ] Sesi lama bisa dibuka, di-unlock, skor lama tampil.
- [ ] Mengubah preset sesi kosong berhasil.
- [ ] Mengubah preset sesi berset ditolak dengan pesan jelas.
- [ ] Clear set lalu ganti preset berhasil.
- [ ] Share link sesi BO3 dibuka di jendela privat.
- [ ] Keyboard-only mengisi 3 set.
- [ ] Layar 360 px: tidak ada input yang terpotong.

---

## 17. Risiko, rollback, dan hal yang ditunda

### 17.1 Risiko

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Ada pembaca yang terlewat dan masih membaca `score_a` | BO3 tidak terhitung / menang salah | Daftar pembaca di §3 + grep `score_a` di semua modul; test integration per pembaca |
| Parity berubah tanpa sengaja | Regresi diam-diam | P0 memisahkan field baru dari angka lama; papan diuji dengan golden number §11.A |
| Papan bergerak saat rilis | Pertanyaan "kok poinku turun" | Dokumentasi §10–11 + pengumuman sebelum deploy; total per match tidak berubah |
| Snapshot lama vs papan baru | `prevRank`/`rankDelta` bergerak sekali; `rank_streak` tidak sinkron | Biarkan snapshot historis; catat di rilis. Rebuild snapshot = tool terpisah (§19) |
| Config salah membuat proses gagal start | API mati | Validasi saat load, seed + migrasi diuji di DB kosong dan DB lama |
| Swap kehilangan set | Data hilang | Test swap BO3; transaksi tunggal |
| Regenerate jadwal menimpa pemain sementara set tetap ada | Set menempel ke pemain baru | `putSchedule` tidak menyentuh set (sama seperti skor lama); UI memperingatkan bila match berset; test integration memastikan set tidak hilang diam-diam |
| UI mengizinkan set keempat | Error server berulang | Validasi klien + tombol tambah set nonaktif |
| Preset dihapus saat ada sesi draft | Create/patch gagal | Pesan `INVALID_PRESET` yang menyuruh pilih ulang; snapshot sesi lama aman |
| `changeEndsAt` disalahartikan sebagai aturan | Operator bingung | Label "petunjuk ganti sisi", tidak memblokir input |

### 17.2 Rollback

- **Sebelum ada sesi BO3**: revert kode + biarkan migrasi 0029 (aditif). UI lama
  menulis `score_a/score_b` seperti biasa; view dan `game_sets` tidak dipakai.
  Data sesi lama tetap utuh.
- **Setelah ada sesi BO3**: rollback kode akan menghilangkan skor BO3 (hanya ada
  di `game_sets`). Jangan rollback; lakukan forward-fix. Ini sama dengan
  kebijakan migrasi destruktif lain di repo.
- Down SQL 0029 (hanya untuk environment tanpa data BO3):

```sql
drop view session.game_results;
drop table session.game_sets;
alter table session.games drop constraint games_identity_unique;
alter table session.sessions
  drop column scoring_rules,
  drop column scoring_preset;
```

### 17.3 Ditunda

- Turnamen (format, poin, bracket).
- Preset custom lewat UI admin.
- Tampilan set di halaman ranking komunitas.
- Statistik per set (mis. "set paling ketat").
- Format selain best-of-3 (mis. best-of-5) — engine sudah mendukung
  `gamesToWin` 1..5, UI belum.
- Penghapusan `rating.score_target` dan kolom skor lama (P4).

---

## 18. Daftar berkas yang disentuh

### Backend

| Berkas | Perubahan |
|---|---|
| `modules/platform/config/registry.nim` | 2 key baru + validasi |
| `db/seeds/platform_config.sql` | 2 baris seed |
| `db/migrations/0029_scoring_presets.sql` | skema + backfill + view |
| `modules/session/scoring.nim` | **baru** — engine murni |
| `modules/session/tests/scoring_test.nim` | **baru** |
| `modules/session/schedule.nim` | `setSets`, `setPlayed`, guard |
| `modules/session/write.nim` | `scoringPreset` di patch + node |
| `modules/session/standings.nim` | view |
| `modules/session/swap.nim` | pindahkan set |
| `modules/session/tests/integration/*` | test baru |
| `modules/rating/projection.nim` | view + `points_to_win` |
| `modules/rating/infrastructure/ingest.nim` | view |
| `modules/rating/read.nim` | riwayat & lawan/partner |
| `modules/achievement/infrastructure/backfill.nim` | view |
| `apps/api/src/app.nim` | create, patch, skor, detail, share |
| `apps/api/src/config_routes.nim` | validasi default preset + `scoringPresets` |
| `tools/import/main.nim` | tulis `game_sets` saat impor skor |
| `packages/contracts/openapi/core.yaml` | deskripsi sesi/game/share |
| `packages/contracts/openapi/community.yaml` | deskripsi config + settings |
| `packages/contracts/openapi/api.yaml` | hasil regen |
| `packages/contracts/openapi/CONTRACT.sha256` | hasil regen |

### Frontend

| Berkas | Perubahan |
|---|---|
| `apps/web/src/legacy/pages/SetupPage.tsx` | kartu format |
| `apps/web/src/legacy/components/summary/useScoreDraft.ts` | draft per set |
| `apps/web/src/legacy/components/summary/ScheduleGrid.tsx` | panel set |
| `apps/web/src/legacy/components/summary/SlotGameCard.tsx` | tampilan ringkas |
| `apps/web/src/legacy/components/summary/PlayerMatchDetailSheet.tsx` | rincian set |
| `apps/web/src/legacy/store/scheduleSlice.ts` | aksi skor |
| `apps/web/src/legacy/utils/scoreValidation.ts` | aturan preset |
| `apps/web/src/legacy/utils/sessionSnapshot.ts` | update optimistis |
| `apps/web/src/legacy/utils/standings.ts` | set-aware |
| `apps/web/src/legacy/queries/sessions.ts` | tipe & payload |
| `apps/web/src/legacy/queries/endpoints.ts` | body `sets` |
| `apps/web/src/legacy/pages/InstagramPostPage.tsx` | rincian set |
| `apps/web/src/legacy/utils/canvasPost.ts` | pemenang dari `winner`, bukan skor |
| `apps/web/src/legacy/components/SummaryModal.tsx` | teruskan data set |
| `apps/web/src/community/api.ts` | kirim `scoringPresets` |
| `apps/web/src/community/useCommunityConfig.ts` | ekspos daftar preset |
| `apps/web/src/pages/SettingsPage.tsx` | select default |
| `apps/web/src/i18n/en.ts` | string baru |

### Dokumentasi

| Berkas | Perubahan |
|---|---|
| `docs/handbook/data-model.md` | tabel baru, view, config |
| `docs/handbook/current-status.md` | jumlah migrasi/key |
| `docs/DECISIONS.md` | ADR format skor |
| `docs/plan/scoring-presets.md` | dokumen ini |

---

## 19. Pertanyaan terbuka

Tidak ada yang menghalangi P0. Yang masih terbuka dan bisa dijawab nanti:

1. **Snapshot historis.** Papan dihitung ulang dengan target 30, tetapi
   `rating.snapshots` lama tetap berisi angka 21. Usul: biarkan (badge
   `rank_streak` tidak berubah, `prevRank` hanya bergerak sekali). Kalau pemilik
   ingin riwayat snapshot ikut dihitung ulang, itu tool terpisah yang memutar
   ulang tanggal — belum termasuk.
2. **Label format di daftar sesi.** Menampilkan chip "BO3 21" di
   `SessionListPage` akan mengubah respons `GET /sessions` (parity). Ditunda
   sampai ada kebutuhan nyata.
3. **Preset keempat.** Menambah format = mengubah `session.scoring_presets`
   saja, tanpa rilis. UI otomatis menampilkannya karena membaca config.
4. **Turnamen.** Kalau nanti ikut, ia butuh pemetaan `phase → rules` sendiri,
   bukan memakai preset sesi.
5. **Statistik per set.** Belum ada kebutuhan; bisa diturunkan dari view tanpa
   migrasi baru kalau diminta.

---

## Lampiran A — Contoh snapshot lengkap

Sesi baru MAJADU 30:

```json
{
  "scoring_preset": "majadu30",
  "scoring_rules": {
    "id": "majadu30",
    "label": "MAJADU 30",
    "mode": "preset",
    "gamesToWin": 1,
    "pointsToWin": 30,
    "winBy": 1,
    "deuceAt": null,
    "maxPoints": 30,
    "changeEndsAt": 15
  }
}
```

Sesi baru Classic 21:

```json
{
  "scoring_preset": "classic21",
  "scoring_rules": {
    "id": "classic21",
    "label": "Classic BO3 21",
    "mode": "preset",
    "gamesToWin": 2,
    "pointsToWin": 21,
    "winBy": 2,
    "deuceAt": 20,
    "maxPoints": 30,
    "changeEndsAt": 11
  }
}
```

## Lampiran B — Contoh query pembaca setelah migrasi

Papan (proyeksi sesi):

```sql
select e.source_id::text as source_id, e.local_date::text as local_date,
       r.round_no, r.court_no, r.winner, r.points_a, r.points_b,
       coalesce((s.scoring_rules->>'pointsToWin')::int, $4)::int as target
from rating.events e
join session.game_results r
  on r.community_id = e.community_id and r.session_id = e.source_id
join session.sessions s
  on s.community_id = e.community_id and s.id = e.source_id
where e.community_id = $1::uuid and e.event_type = 'session'
  and e.local_date >= $2::date - ($3::int * 7)
  and e.local_date <= $2::date
  and s.approved_at is not null
  and r.status = 'played' and r.winner <> ''
order by e.local_date, r.round_no, r.court_no;
```

Achievement:

```sql
select r.session_id::text as session_id,
       r.round_no, r.court_no, r.winner,
       coalesce(g.side_a1::text, '') as a1, ...
from session.game_results r
join session.games g
  on g.community_id = r.community_id and g.session_id = r.session_id
 and g.round_no = r.round_no and g.court_no = r.court_no
join session.sessions s
  on s.community_id = r.community_id and s.id = r.session_id
where r.community_id = $1::uuid
  and r.status = 'played' and r.winner <> ''
  and s.approved_at is not null
  and s.status in ('locked', 'published', 'completed', 'archived');
```

## Lampiran C — Ringkasan angka kunci

| Item | Sebelum | Sesudah |
|---|---|---|
| Target rating sesi | 21 (semua) | `pointsToWin` snapshot: 30/21/15 |
| Poin 30–28 | 136.90 | 133.33 |
| Poin 30–5 | 250.00 | 229.17 |
| Match BO3 21–19, 21–19 | tidak ada | 136.90 |
| Match BO3 21–19, 19–21, 21–19 | tidak ada | 128.97 |
| Game count per match BO3 | tidak ada | 1 |
| Entry papan per sesi | 1 | 1 |
| best-N | 10 | 10 |
| Standings shape | sama | sama |
