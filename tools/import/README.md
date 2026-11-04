# tools/import

ETL sekali-jalan dari database v1 (`bm_staging`) ke v2. T-064.

## Status

| Domain | Sumber v1 | Tujuan v2 | Keadaan |
|---|---|---|---|
| Pemain | `bm.players` | `player.players` | sudah |
| Alias | `bm.player_aliases` | `player.aliases` | sudah |
| Sesi + jadwal + skor | `bm.sessions`, `bm.session_players`, `bm.scheduled_games`, `bm.scheduled_game_players` | `session.*` | belum |
| Rating | `bm.rating_*` | `rating.*` | belum |
| Turnamen | `bm.tournament_*` | `tournament.*` | belum |
| Badge, snapshot | `bm.player_achievements`, `bm.rank_snapshots` | dihitung ulang | belum |

Perintah `etl` mencetak `skippedDomains`; `verify` mencetak `uncheckedDomains`.
Jangan membaca keluaran "problems: 0" sebagai "seluruh database sama" selama
daftar itu belum kosong.

## Jalankan

```sh
MAJADU_ETL_SOURCE_DSN=postgresql://.../bm_staging \
MAJADU_PG_DSN=postgresql://.../bm2 \
  .cache/bin/majadu-import etl --slug majadu --name "Majadu"

# harga diri: bandingkan, jangan percaya
MAJADU_ETL_SOURCE_DSN=... MAJADU_PG_DSN=... \
  .cache/bin/majadu-import verify --slug majadu
```

- `--timezone` opsional; tanpa itu dibaca dari `community.default_timezone` di
  `platform.config`. Tidak ada default di kode.
- `--dry-run` menghitung tanpa menulis.
- `MAJADU_IMPORT_COMMUNITY_ID` menunjuk komunitas yang sudah ada, misalnya saat
  melanjutkan import yang terputus.

Bangun binernya:

```sh
nim c -d:release -o:.cache/bin/majadu-import tools/import/main.nim
```

## Sifat yang dijanjikan

1. **Idempoten.** Setiap baris yang ditulis punya entri di `import.row_map`
   (`community_id`, `entity`, `old_id` → `new_id`). Jalan kedua memakai id yang
   sama dan meng-update, bukan menyalin.
2. **Satu transaksi untuk tulisan.** Sumber hanya dibaca; seluruh tulisan ke v2
   berada dalam satu transaksi per domain.
3. **Nama ganda dilipat.** v2 mewajibkan `canonical_name` unik per komunitas; v1
   tidak. Dua baris v1 bernama sama menjadi satu pemain, dan `collapsed`
   menghitungnya — bukan dianggap selisih.
4. **Tidak membuat keanggotaan atau tautan.** Import memindahkan data, bukan hak
   akses; user dan share link tidak dibawa (T-064).

## Uji

Test menulis ke dua database, jadi arahkan ke database buangan:

```sh
MAJADU_IMPORT_TEST_SOURCE_DSN=postgresql://.../bm_staging \
MAJADU_IMPORT_TEST_DSN=postgresql://.../bm2_scratch \
  nim c -r -o:.cache/bin/import_test tools/import/tests/import_test.nim
```

Tanpa kedua variabel itu, suite dilewati (bukan lulus diam-diam: pesan
"skipped" dicetak).
