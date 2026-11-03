# Memo 03 — Strategi Data: skema, migrasi, DB dev, parity

> **Tanggal:** 3 Nov 2026 · **Panel:** data architect · **Target:** backend Nim untuk
> `badminton-match`, v1 (Go) tetap jalan.
> **Basis fakta:** dump skema nyata `.local/schema-bm-2026-11-03.sql` (26 tabel, 26 index,
> 4 fungsi — dibaca penuh), `docs/audits/2026-11-03/{07-database,02-backend,03-ci}.md`,
> ETL terbukti di `~/Projects/majadu` (`docs/migration/*`, `tools/importer`), dan runner
> migrasi `~/Projects/cbs/tools/dbtools`.
> **Aturan:** memo ini tidak memuat isi dump, data, secret, atau IP. Semua klaim skema
> dirujuk ke nomor baris dump, bukan ke ingatan.

---

## 0. Koreksi terhadap audit — wajib dibaca sebelum memakai daftar perbaikan

Dump mengalahkan audit di enam titik. Rencana yang menyalin audit apa adanya akan
mengerjakan hal yang sudah ada dan melewatkan yang benar-benar hilang.

| Klaim audit | Keadaan nyata (dump) | Konsekuensi |
|---|---|---|
| `rating_deltas` tidak punya `UNIQUE(event_id, player_id)` (07:P2-1) | PK `rating_deltas_pkey PRIMARY KEY (event_id, player_id)` (`schema:922-923`); CHECK `team`/`outcome` juga sudah ada (`:371-372`) | Dedupe + `ADD CONSTRAINT` **tidak perlu**. Risiko duplikat beralih ke `merge_players` yang membuang delta konflik tanpa jejak (`schema:130-134`) |
| Index `rating_deltas(event_id)` hilang (07:P1-4) | PK berawalan `event_id` sudah melayaninya (`:922`) | Yang kurang hanya bentuk *covering* `(event_id, team, player_id)` untuk self-join `opp_tiers` |
| Index urut 4 kolom hilang (07:P1-4, 02:P2-10) | `rating_events_order_uniq UNIQUE (date, created_at, source_id, game_order)` (`:938-939`) membuat index tepat untuk `ORDER BY` itu | `idx_rating_events_sort_lookup (id, date…)` (`:1287-1288`) **mubazir** — drop, bukan tambah |
| `stats.go` filter `player_id` seq scan (07:P1 tabel #8) | `bm_session_players_player_id_idx` (`:1196-1197`) dan `(player_id, session_id, updated_at DESC, internal_id DESC)` (`:1200-1204`) ada | Tidak ada pekerjaan |
| `sessions.status` tanpa CHECK (07:P3-7) | CHECK 5 nilai ada (`:562-563`) | Jangan tambah CHECK ke tabel v1 — akan gagal pada nilai legacy |
| `sessions` PK tidak terpakai karena `id::text` | PK `id` ada (`:1010-1011`), `share_code` UNIQUE (`:1015-1019`) | Masalahnya murni pola query (`rating_extract.go:51`, `rating_revert.go:142,168,178`, `team_tournament.go:23`), bukan skema |

Temuan yang **terkonfirmasi** dan menjadi dasar §3: `DeletePlayer` (`rating_admin.go:119-121`),
`Save()` menghapus lalu menulis ulang `scheduled_games` (`session_write.go:304` + `:500`),
`000020` destruktif (`docs/backend/000020_purge_glicko.sql`), `000023` menimpa tuning
(`docs/backend/000023_adjust_tournament_points.sql:25-37`), timezone (`achievement.go:586-588`),
dan pola `share_code = $1 OR id::text = $1`.

Tambahan yang tidak ada di audit mana pun, terlihat dari dump:
- **Enam pasang index duplikat** dari 26: `idx_rating_deltas_player_event`≡`rating_deltas_player_idx`
  (`:1278`,`:1313`); `idx_session_players_session_player`≡UNIQUE `(session_id, player_id)`
  (`:1306`,`:807-811`); `rating_events_match_key_key`≡`rating_events_match_key_idx`
  (`:927`,`:1320`); `rating_events_seq_key`≡`rating_events_seq_idx` (`:951`,`:1327`);
  `bm_scheduled_games_session_internal_slot_court_idx`≡UNIQUE (`:1180`,`:775-779`);
  `bm_session_courts_session_internal_court_idx`≡UNIQUE (`:1187`,`:791-795`).
- **`players.canonical_name` UNIQUE tanpa normalisasi** (`:879-883`) padahal
  `player_aliases.alias_name` punya CHECK normalisasi (`:300-301`) → "Budi" dan "budi " bisa
  jadi dua identitas; `normalize_player_name()` ada (`:178-185`) tapi tidak dipakai di sini.
  `sessions.version` juga `integer` sedangkan `scheduled_games.version` `bigint`
  (`:557`,`:485`) — dua skala OCC yang tidak sebanding.
- **`fix_matches` slot FK `ON DELETE SET NULL`** (`:1431-1459`) + `Save()` menghapus
  `scheduled_games`/`session_players` (`session_write.go:304,337`) → setiap publish
  mengosongkan `fix_matches.slot_*`. Batasan pasangan hilang diam-diam, bukan hanya `version`.

---

## 1. Keputusan strategi skema

Tiga opsi, dievaluasi pada enam kriteria. Bobot: risiko data 30%, biaya migrasi 20%,
biaya FE 15%, biaya test 20%, kerja paralel 15%.

| Kriteria | (a) `bm` 1:1 | (b) evolve `bm` in place (additive) | (c) redesign, skema baru + import |
|---|---|---|---|
| Risiko data | **Tinggi.** Enam cacat §0 ikut pindah, karena `Save()`/`DeletePlayer` ada di *jalur tulis* yang ditiru | **Tinggi.** v1 hidup di `bm`; setiap `ALTER` menyentuh tabel yang sedang ditulis v1, dan additive-only tidak bisa memperbaiki jalur tulis | **Rendah.** Nol DDL pada `bm`; cacat diperbaiki di tempat lahirnya |
| Biaya migrasi | 0 | Rendah (DDL), tinggi tersembunyi (koordinasi rilis dengan v1) | Sedang, **terbukti**: `platform.import_row_map`/`import_check` sudah dipakai majadu (`modules/platform/migrations/0024_import.sql:9-46`) |
| Biaya FE | 0 | 0 | Sedang: `public_id` vs `share_code`, `games.version`, payload `rank` |
| Biaya test | Rendah awalnya, tinggi kemudian (fixture meniru skema yang tak bisa dibangun dari repo) | Sedang | Rendah: skema dari berkas bernomor → CI bisa `psql -f` (menutup 03-ci:P1-1) |
| Kerja paralel | Tinggi untuk baca, **nol** untuk tulis (semua menunggu rilis v1) | Rendah: satu migrasi salah = v1 down | **Tinggi**: tiap subagent punya schema sendiri (§4) |
| Bisa dibangun dari repo | **Tidak** (`docs/backend/README.md:21-22`) | Tidak | **Ya**, itu tujuannya |

### Verdict: **(c) redesign — skema baru `bm2` di instance PostgreSQL yang sama, diimpor dengan pola majadu, tetapi dipersempit**

Alasan yang menentukan:
1. `bm` **tidak dapat direkonstruksi dari repo** (07:P1-1). Selama itu benar, "perbaikan
   skema" di `bm` adalah suntingan pada artefak tanpa sumber. Skema baru dari berkas
   bernomor menutup itu sekaligus celah CI (03-ci:P1-1) tanpa DB VPS.
2. Redesign membuat cacat §0 hilang **secara struktural**: `DeletePlayer` tidak bisa
   merusak pemain lain bila `rating.deltas` tidak cascade dari `events`.
3. Biaya migrasinya sudah dibayar majadu: klasifikasi per tabel ada di
   `~/Projects/majadu/docs/migration/MAPPING.md:18-46`, dan comparator murah karena
   `rating_deltas` tidak menyimpan angka (`MAPPING.md:297-300`).

**Penyempitan yang disengaja** (jangan menyalin majadu bulat-bulat): tanpa `community_id`,
tanpa auth/membership, tanpa multi-tenant. Satu komunitas, satu host = admin token. Tabel
target ±18, bukan 26: `player`, `session`, `tournament`, `rating`, `rank`, `achievement`,
`platform`. Skema tetap `bm2` agar jelas ini bukan `bm`.

**Fallback** bila import tidak terbukti dalam anggaran: opsi **(b), tetapi dibekukan** —
`bm` tidak menerima DDL sama sekali; semua perbaikan dikirim sebagai perubahan kode + satu
skema bayangan `bm2_shadow` yang hanya dibaca (view/read-model) untuk membandingkan hasil.
Fallback ini secara eksplisit **menerima** bahwa `DeletePlayer`/`Save` hanya diperbaiki di
level kode, dan bahwa `bm` tidak reproducible sampai v1 pensiun. Catat sebagai utang, bukan
sebagai keadaan akhir.

---

## 2. Ledger migrasi

Adopsi `cbs/tools/dbtools` apa adanya — ia sudah memuat semua yang dibutuhkan dan sudah
dipakai di repo Nim lain.

**Tata letak.** `db/migrations/NNNN_slug.sql`, satu berkas = satu transaksi, berkas
**tidak boleh** memuat `BEGIN/COMMIT/ROLLBACK` (runner yang mengelola; ditegakkan
`cbs/tools/dbtools/lib.nim:232-238`). Urutan global deterministik `(seq, nama berkas)`
(`lib.nim:241-269`).

**Ledger.**
```sql
create schema if not exists platform;
create table if not exists platform.schema_migration (
  migration_id text primary key,      -- 'session/0007_games'
  module       text not null,
  filename     text not null,
  seq          int  not null,
  sha256       text not null,
  destructive  boolean not null default false,
  applied_at   timestamptz not null default now(),
  duration_ms  int not null default 0
);
```
Bentuk ini persis `cbs/tools/dbtools/lib.nim:59-74` (bootstrap). Checksum dihitung **di DB**
lewat `digest()`/pgcrypto, bukan implementasi sendiri (`lib.nim:402-404`) — supaya tidak ada
dua definisi "isi berkas".

**Idempotensi.** Berkas yang sudah tercatat dilewati; `migrate` dua kali aman. Berkas yang
sudah diterapkan **tidak boleh berubah isi** — checksum berbeda = `fail`, bukan peringatan
(`lib.nim:540-544`). Ini yang menggantikan "ingat-ingat saja" di `docs/backend/README.md:25`.

**Satu penulis.** `pg_advisory_lock(hashtext('<app>.dbtools.migrate'))` dipegang selama
migrasi (`lib.nim:523`). Dua operator, dua proses, satu pemenang.

**Guard destruktif.** DDL merusak (`drop table/column/constraint`, `truncate`, `rename
column`) ditolak kecuali berkas menandai alasannya di header:
`-- dbtools:destructive <alasan>` (`lib.nim:12-15,165-183,224-230`). Pola **expand/contract**
dua jalur: berkas `-- dbtools:contract <alasan>` tidak pernah diterapkan jalur expand, dan
jalur contract menolak jalan selama masih ada expand tertunda (`lib.nim:504-537`). Artinya
"hapus kolom" adalah migrasi tersendiri yang disengaja, bukan efek samping.

**Boot vs CLI.** Keputusan: **`tools/dbmigrate` memiliki DDL; aplikasi hanya memverifikasi.**
Saat start, server memanggil `status --check` in-process: bandingkan himpunan `migration_id`
+ checksum terhadap berkas; tertunda atau berbeda → **refuse to start**, sebut berkasnya.
Alasan menolak "apply at boot": DDL berebut lock antar replika, tak terlihat operator, dan
bertabrakan dengan expand/contract dua fase. `/readyz` melaporkan versi skema minimum yang
dibutuhkan kode (bukan `Pool.Ping` seperti `apps/api/internal/handler/health.go:26-38`) dan
`migration_health()` memeriksa objek kunci — menutup 07:P1-1 dan 02:P2-11 sekaligus.

**Baseline untuk 12 migrasi yang hilang.** Jangan merekonstruksi `000001–000012`.
1. `0001_baseline.sql` untuk `bm2` = satu berkas yang dihasilkan dari **dump skema saat ini**,
   sudah dibersihkan (`\restrict`, owner, ACL, `SET` session dibuang), lalu di-commit dengan
   checksum. Baseline = keadaan terukur, bukan rekaan.
2. `0002+` = perbaikan §3. Karena baseline sudah "post-000020", tidak ada berkas yang
   menghapus kolom Glicko — kelas migrasi yang paling berbahaya tidak pernah ada di repo ini.
3. Untuk `bm` (v1): buat `bm.schema_migration` sebagai **ledger observasi**, diseed 23 baris
   `000001..000023` dengan `applied_at` dari arsip VPS, dan **tidak pernah** ditulis oleh
   runner kita. Gunanya satu: `status` bisa mengatakan "v1 sudah 000023, bukan 000019".
   Tanpa ini, satu-satunya cara mengetahui versi v1 adalah bertanya ke operator.
4. Migrasi `bm` baru (bila benar-benar perlu) mulai `000024`, memakai `SET LOCAL search_path`
   alih-alih prefiks `bm.` hardcode — sumber drift yang sudah tercatat (07:P3-1).

---

## 3. Perbaikan konkret (folded into `bm2`)

Setiap butir: cacat → DDL/perilaku baru. Yang berupa kode ditandai **[kode]** karena
DDL saja tidak menutupnya.

### 3.1 `DeletePlayer` menghapus fakta pemain lain
Cacat: `DELETE FROM rating_events WHERE id IN (SELECT event_id … player_id = $1)`
(`rating_admin.go:119-121`) → `rating_deltas` peserta lain ikut cascade (`schema:1506-1507`).
`RebuildAll` tidak membuat ulang event yang sudah hilang.

```sql
-- bm2: delta bukan milik event secara eksistensial
create table rating.deltas (
  event_id  uuid not null references rating.events(id) on delete restrict,
  player_id uuid not null references player.players(id) on delete restrict,
  side      text not null check (side in ('A','B')),
  outcome   text not null check (outcome in ('W','L')),
  primary key (event_id, player_id)
);
```
`on delete restrict` pada `events` membuat pola lama **gagal keras** alih-alih menghapus
diam-diam. Hapus pemain = hapus `rating.deltas` miliknya + `rating.player_stats`, event tetap.
**[kode]** `delete_player(p_id, p_force)` mengembalikan `{deltas_deleted, events_kept}` dan
menolak bila `p_force` tanpa `backup_verified` (lihat §6).

### 3.2 `scheduled_games.version` reset saat Save
Cacat: `DELETE FROM scheduled_games` (`session_write.go:304`) lalu `INSERT` tanpa `version`
(`:500`) → `DEFAULT 1` (`schema:485`). Klien granular dengan `If-Match` lama lolos.

```sql
create table session.games (
  id uuid primary key,
  session_id uuid not null references session.sessions(id) on delete cascade,
  round_no int not null, court_no int not null,
  version bigint not null default 1,
  score_a int, score_b int, played_at timestamptz,
  unique (session_id, round_no, court_no)
);
create trigger games_version_guard before update on session.games
  for each row execute function session.bump_game_version();  -- version++ hanya di sini
```
**[kode]** Save = upsert, bukan delete+insert:
`insert … on conflict (session_id, round_no, court_no) do update set …, version = games.version + 1`.
Baris yang hilang dari snapshot dihapus **hanya bila** `played_at is null` (guard trigger
menolak delete game yang punya skor). Ini juga menyelamatkan `fix_matches` (§0) karena
`internal_id` tidak lagi lahir ulang setiap publish.

### 3.3 Index — tambah yang terukur hilang, buang yang duplikat
```sql
create index player_achievements_key_idx on achievement.player_achievements (achievement_key);
create index sessions_date_updated_idx on session.sessions (session_date desc, updated_at desc);
create index rating_deltas_event_team_idx on rating.deltas (event_id, side, player_id);
create index tournament_matches_pair_a_idx on tournament.matches (pair_a_id);
create index tournament_matches_pair_b_idx on tournament.matches (pair_b_id);
```
`(event_id, side, player_id)` khusus untuk self-join `opp_tiers` di papan poin
(`rank_points.go:318-324`) — PK `(event_id, player_id)` sudah menutup filter biasa, jadi ini
bukan pengganti melainkan penutup jalur kuadratik.
`(date)` dan urutan 4 kolom **tidak** ditambahkan: sudah dilayani `rating_events_order_uniq`.
Di `bm`, index mubazir **tidak** di-drop selama v1 hidup (men-drop index v1 = perubahan
performa produksi tanpa uji); catat sebagai daftar kontrak untuk saat v1 pensiun.
`ILIKE '%q%'` pada judul: pakai `pg_trgm` + `gin (title gin_trgm_ops)` **atau** batasi ke
prefix — putuskan saat endpoint `/sessions` ditulis, bukan sekarang.

### 3.4 `000020` destruktif tanpa guard
`bm2` lahir setelah Glicko; tidak ada berkas yang perlu men-drop 10 kolom. Guard yang tetap
dipasang:
- Semua DDL merusak wajib header `-- dbtools:destructive`; runner menolak tanpa itu (§2).
- `dbmigrate migrate` mencetak ringkasan destruktif + meminta `--allow-destructive` eksplisit
  di CLI, bukan `SET bm.allow_destructive = on` (variabel sesi mudah terlupa).
- `bm.assert_baseline()` di `bm` memeriksa keberadaan objek pasca-020
  (`scheduled_games.version`, `idempotency_keys`, `rank_snapshots`, `player_achievements`);
  `000024+` menolak jalan bila signature tidak cocok. Ini mencegah "menjalankan migrasi baru
  pada DB pra-020" — kegagalan yang tidak terdeteksi apa pun hari ini.

### 3.5 `000023` menimpa tuning operator
Cacat: `UPDATE … SET champion_points = 2500 …` tanpa syarat
(`docs/backend/000023_adjust_tournament_points.sql:25-37`), berbeda dari pola
`ON CONFLICT DO NOTHING` di `000018`.

```sql
-- seed hanya bila baris masih benih
insert into rank.point_levels (kind, champion_points, round_ratios)
values ('tournament_classic', 2500, '{…}'::jsonb), ('tournament_team', 3000, '{…}'::jsonb)
on conflict (kind) do nothing;

update rank.point_levels set champion_points = 2500, round_ratios = '{…}'::jsonb
where kind = 'tournament_classic'
  and champion_points = 0 and round_ratios = '{}'::jsonb;   -- belum pernah disentuh
```
Perubahan angka setelah itu adalah **data**, bukan migrasi: masuk `platform.config_history`
(pola `majadu/modules/platform/migrations/0031_config_history_backstop.sql`) sehingga
"kenapa poin berubah" punya jawaban dan tidak perlu tebak-tebakan dari diff SQL.

### 3.6 Uniqueness `rating_deltas` — sudah ada, sisanya di merge
PK `(event_id, player_id)` sudah benar (§0). Yang belum dijaga:
```sql
-- merge tidak boleh membuang fakta tanpa jejak
create table platform.merge_log (
  id bigint generated always as identity primary key,
  target_player_id uuid not null, source_player_id uuid not null,
  deltas_dropped int not null, snapshots_dropped int not null,
  performed_at timestamptz not null default now(), note text not null default ''
);
```
`merge_players` hari ini menghapus delta konflik (`schema:130-134`) lalu pemanggil
`RebuildAll` — hasilnya benar, tapi tidak ada catatan berapa fakta yang hilang. Di `bm2`,
merge menulis `merge_log` dan mengembalikan angkanya di respons (pola yang sudah dipakai
`delete_player`, `schema:73-79`).

### 3.7 Timezone
Cacat: `sessions` memakai `date` + `time without time zone` dan SQL sadar WIB
(`session_write.go:170-175`), sedangkan `earned_at` memakai zona proses
(`achievement.go:586-588`); container UTC.

```sql
create function platform.today_local() returns date language sql stable
  as $$ select (now() at time zone 'Asia/Jakarta')::date $$;

alter table achievement.player_achievements
  add constraint earned_not_future check (earned_at <= platform.today_local() + 1);
```
Aturan: **tidak ada** `date` yang dihitung di Nim. Semua tanggal bisnis berasal dari
`platform.today_local()` atau dari parameter request yang sudah divalidasi bentuknya.
`timestamptz` hanya untuk instant (`created_at`, `played_at`). Role aplikasi menyetel
`timezone = 'UTC'` secara eksplisit supaya perilaku tidak bergantung pada image.

### 3.8 `share_code OR id::text` mematikan PK, dan `share_code` = kunci tulis
Cacat ganda: 15 titik query (`rating_extract.go:51`, `rating_revert.go:142,168,178`,
`team_tournament.go:23`, dst.) memaksa seq scan, **dan** `GET /sessions` mempublikasikan
`share_code` (02-backend:P1-1).

```sql
create table session.share_links (
  code text primary key check (code ~ '^[a-z0-9]{6,32}$'),
  session_id uuid not null references session.sessions(id) on delete cascade,
  label text not null default '',
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);
create index share_links_session_idx on session.share_links (session_id);
```
`session.sessions.public_id uuid` = identitas tampilan (aman dipublikasikan).
Handler memilih **satu** kunci bertipe sebelum query: `public_id` (uuid, PK) atau
`share_links.code` (PK). Tidak ada `OR`, tidak ada `::text` pada kolom. Rotasi/revoke link
jadi mungkin tanpa mengganti identitas sesi.

---

## 4. DB dev lokal (Podman, tanpa data produksi)

**Bentuk.** Satu pod, satu container, satu volume: `ops/dev/podman-compose.yml` (atau
`ops/dev/pg-up.sh` bila compose tidak tersedia). Image `postgres:18-alpine` — dump dari 18.6
(`schema:7`), jangan turun versi. Port `55432` (bukan 5432, agar tidak bertabrakan).
`--health-cmd pg_isready --health-interval 2s --health-retries 20`. Volume `bmdev-pgdata`
persisten + `bmdev-pgdata-fast` di tmpfs untuk reset. `POSTGRES_DB=badminton_dev`,
`POSTGRES_INITDB_ARGS=--data-checksums`.

**Penamaan per-subagent.** Satu database, banyak skema:
`bm2_<agent>` — `bm2_data`, `bm2_api`, `bm2_fe`, `bm2_ci`.
`task db:agent <nama>` membuat skema kosong dari template (di bawah). Aturan yang
ditegakkan skrip, bukan didokumentasikan: nama harus cocok `^bm2_[a-z]{2,8}$`; `bm` dan
`public` **ditolak** (`cbs/tools/dbtools/main.nim:107-110` adalah preseden penolakan
bernama).

**Kecepatan reset.** Template database, bukan `pg_dump`/`restore` per reset:
```
createdb bm2_template           # sekali: migrate + seed
createdb -T bm2_template bm2_api   # ±200 ms, skema + seed siap
```
Reset satu agen = `dropdb bm2_api && createdb -T bm2_template bm2_api`. Target: pindah
schema <1 s, reset penuh <3 s, pod dingin <20 s (image sudah ada). Ini yang membuat
"jalankan test integrasi" tidak lagi terasa mahal — akar 03-ci:P1-1.

**Seed = fixture, bukan dump.** `db/fixtures/*.sql`, UUID deterministik (konstanta, bukan
`gen_random_uuid()`): 12 pemain + alias, 2 sesi (draft + locked berskor), 1 turnamen classic,
1 turnamen team, `rating_config` + `point_levels`. Nol baris produksi;
`db/fixtures/README.md` melarang menambah dump.

**Isolasi test integrasi.** Satu skema per **proses** test: `bm2_test_<pid>`, dibuat dari
`bm2_template` di setup, di-drop di teardown (`drop schema … cascade`). Guard di setup:
tolak bila `current_database() in ('bm','postgres')` atau `BM_ENV=prod`. Test tidak boleh
menghitung baris global — perbaiki juga tiga test yang hari ini begitu
(`docs/backend/README.md:38-41`), karena dengan template mereka tidak lagi punya alasan.

**Garis besar skrip (bukan kode lengkap).**
| Berkas | Tanggung jawab | Keluar |
|---|---|---|
| `ops/dev/pg-up.sh` | podman run + tunggu health + buat `bm2_template` | 0/1 |
| `ops/dev/pg-down.sh` | stop container, volume tetap | 0 |
| `ops/dev/pg-reset.sh <schema>` | validasi nama → drop/create dari template → seed opsional | 0/1/3 |
| `ops/dev/pg-snapshot.sh` | `pg_dump -Fc --schema-only` untuk baseline `0001` (§2) | 0 |
| `task db:up / db:reset <agent> / db:migrate / db:seed / db:psql` | pembungkus tipis, satu sumber kebenaran | — |

`task` tetap POSIX, nama target bahasa Inggris (kontrak `/Users/sachiel/Projects/AGENTS.md` §5).

---

## 5. Parity data — membuktikan Nim membaca sama dengan Go

Empat lapis, dari termurah ke termahal. Lapis 1–2 wajib sebelum FE disentuh.

**1. Comparator replay (paling kuat, paling murah).** `rating.deltas` v2 dari replay event
harus **sama persis** dengan `bm.rating_deltas` v1: himpunan `(match_key, player, side,
outcome)`. Tidak ada angka untuk dibandingkan (`~/Projects/majadu/docs/migration/MAPPING.md:297-300`).
Laporan per event/pemain ditulis ke tabel, bukan stdout.

**2. Golden fixtures dari Go, sekali, lalu dibekukan.** Jalankan 48 rute baca Go terhadap
satu DB restored, simpan payload kanonik (key terurut, timestamp dipatok) ke
`apps/api/testdata/parity/<route>.json`; test Nim membandingkan setelah kanonikalisasi.
Preseden: `apps/api/internal/store/readpath_parity_test.go:18-23` — pola sama, oracle dibalik.

**3. Tabel snapshot + laporan divergensi.** Meniru `platform.import_check`
(`~/Projects/majadu/modules/platform/migrations/0024_import.sql:36-46`):
```sql
create table platform.parity_run (
  id uuid primary key, started_at timestamptz not null default now(),
  finished_at timestamptz, status text not null check (status in ('running','ok','failed')),
  counters jsonb not null default '{}'::jsonb
);
create table platform.parity_check (
  id bigint generated always as identity primary key,
  run_id uuid not null references platform.parity_run(id) on delete cascade,
  check_name text not null, expected text not null, actual text not null,
  passed boolean not null, note text not null default ''
);
```
Nama check = `route + field`, sehingga kegagalan menunjuk field, bukan "output beda".

**4. Property test atas matematika poin.** Setelah Glicko pensiun, yang tersisa adalah papan
poin (`rank_points.go`) dengan empat invariant tanpa oracle: `sum(deltas) = wins + losses`;
papan invarian terhadap urutan insert event; `points >= 0` dan best-N monoton; `as_of` sama
→ snapshot identik. Diferensial: generator event sintetis (1.000 seed, seed ditulis di nama
test agar reproducible), jalankan Go dan Nim, bandingkan papan penuh. Ini satu-satunya lapis
yang menguji **logika**, bukan pembacaan.

---

## 6. Risiko data & retensi

**Asumsi backup.** v1 adalah satu-satunya sumber kebenaran sampai cutover. Karena itu:
- Skema `bm2` **disposable**; kehilangannya = jalankan ulang import. Tidak ada backup `bm2`
  sampai ia menerima tulisan yang tidak berasal dari import.
- Sebelum **setiap** import/replay penuh: `pg_dump -Fc` + SHA-256 + **cek ukuran**. Ukuran
  adalah sinyal (pelajaran `skyward`: 19 MB → 31 KB, 07:P1-1). Retensi 90 hari, mode 600,
  di luar repo. Tanpa backup terverifikasi, operasi destruktif menolak jalan — ditegakkan
  skrip, bukan paragraf peringatan seperti hari ini (`docs/backend/README.md:29-32`).
- Dump tidak pernah masuk repo, CI, atau memo. Skema-only dump boleh (itu `0001_baseline.sql`).

**Idempotency & outbox.** Hari ini keduanya tumbuh tanpa pembersih: tidak ada `DELETE` di
seluruh repo (07:P2-3), `idempotency_keys.response` menyimpan snapshot penuh (`schema:230-236`).
Kebijakan `bm2`:
```sql
alter table platform.idempotency_keys
  add constraint idem_ttl check (expires_at > created_at);
-- sweeper di ticker: hapus expires_at < now() - 1h, batch 5000, metrik rows_deleted
create index outbox_pending_idx on platform.outbox_events (created_at)
  where published_at is null;
```
`outbox_events` menjadi antrean (`published_at`, klaim `for update skip locked`), bukan log
abadi; retensi 30 hari setelah publish, dengan jendela replay minimum yang eksplisit.
`idempotency_keys` di `bm2` menyimpan `body_hash` (menutup 02-backend:P1-5), bukan hanya
`session_id+key`.

**Rank snapshot drift.** PK `(as_of, player_id)` tanpa versi definisi (`schema:906-907`);
`000023` mengubah poin tanpa menyegarkan snapshot → panah ^/v membandingkan dua definisi.
```sql
alter table rank.snapshots add column board_rev int not null default 1;
-- board_rev naik saat rank.point_levels berubah (satu tempat: fungsi update_config)
-- panah hanya membandingkan snapshot dengan board_rev yang sama
```
Capture dalam **satu transaksi** dan satu multi-row `INSERT`; hari ini `SendBatch` + `DELETE`
terpisah (`rank_points.go:614-648`) membuat pembaca bisa melihat papan setengah jadi.

**Risiko lain yang harus tercatat di rencana, bukan ditemukan nanti:**
- `rating_events.source_id` polimorfik tanpa FK (`schema:441-449`) → event yatim tetap
  memberi poin. Di `bm2`: `rating.events.session_id`/`tournament_id` sebagai kolom bertipe
  (dua FK, salah satu null) alih-alih string bebas.
- `session_players.player_id` nullable (`schema:517-518`) + FK `RESTRICT` (`:1527-1531`) →
  `delete_player(force)` menghapus baris partisipasi, sehingga kehadiran hilang. `bm2`:
  placeholder adalah pemain nyata dengan `is_placeholder` (pola `MAPPING.md:102-107`).
- `idempotency_keys`/`outbox_events` FK `ON DELETE CASCADE` ke `sessions` (`:1463-1475`) →
  menghapus sesi menghapus bukti idempotensi; di `bm2` tanpa cascade.
- Kapasitas: angka di komentar bertentangan (655 vs 2.5k event; 07:P3-8). Catat
  `select count(*)` saat import — angka itu yang membenarkan keputusan "on-read cukup".

---

## 7. Urutan eksekusi (ringkas) & verifikasi

| # | Langkah | Gerbang |
|---|---|---|
| 1 | Rekam skema v1 sebagai baseline: `pg_dump --schema-only` bersih → `0001_baseline.sql` + checksum | `dbmigrate validate` hijau; berkas < 400 baris, tanpa data |
| 2 | Ledger + runner (`dbmigrate`) + `status --check` di boot + `/readyz` versi skema | Dua kali `migrate` = hasil sama; checksum berubah = gagal |
| 3 | `ops/dev` pod + `bm2_template` + fixture | Reset <3 s; skema agen <1 s |
| 4 | Skema `bm2` + perbaikan §3 (kecuali yang butuh kode) | `0002..000N` masing-masing satu transaksi, satu tujuan |
| 5 | Import (pola majadu): plan → apply → rebuild → verify | `rating.deltas` replay == `bm.rating_deltas` (himpunan) |
| 6 | Parity lapis 2–3 (golden + tabel check) | Semua `parity_check.passed` |
| 7 | Parity lapis 4 (property + diferensial) | 1.000 seed, nol divergensi |
| 8 | Baru FE menyentuh kontrak (`public_id`, `version`, `board_rev`) | FE membaca hanya dari `bm2` |

Verifikasi yang bisa dijalankan siapa pun tanpa membaca memo ini: `dbmigrate status`
(hijau/merah), `task db:reset api` (<3 s), `task parity` (semua baris `passed`), dan
`psql -c 'select count(*) from platform.parity_check where not passed'` = 0.

**Yang tidak dilakukan di fase ini:** DDL apa pun pada `bm`, drop index v1, menyalin data
produksi ke repo, dan menjalankan importer terhadap `bm` hidup. Ketiganya menunggu cutover
yang diputuskan terpisah.
