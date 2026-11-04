# tools/fixtures

Generator data sintetis deterministik untuk skema v1 (`bm`). T-099.

Tidak ada data produksi di sini: nama pemain dibuat-buat, skor diacak dari seed,
dan seluruh timestamp dihitung dari epoch tetap (`2026-09-01T00:00:00Z`), bukan
jam dinding. Seed yang sama selalu menghasilkan berkas SQL yang byte-identik.

## Pakai

```sh
nim c --hints:off -o:.cache/bin/fixtures tools/fixtures/main.nim
.cache/bin/fixtures --seed 7 --out ops/dev/v1/fixtures
```

Hasil default: `ops/dev/v1/fixtures/v1-fixtures.sql`. `--out` juga menerima
nama berkas yang berakhiran `.sql`.

Menerapkan ke database v1 yang sudah direstore dari `ops/dev/v1/schema.sql`:

```sh
psql -v ON_ERROR_STOP=1 -d bm_v1_dev -f ops/dev/v1/fixtures/v1-fixtures.sql
```

Berkas diawali `truncate … restart identity cascade`, jadi aman dijalankan
berulang pada database dev yang sama.

## Isi

12 pemain, 2 sesi (published + draft), 8 game terjadwal (5 berstatus played),
5 rating event + 20 delta, 1 turnamen classic (6 pasang, grup + knockout), dan
1 turnamen team (4 tim, 3 pertandingan). Semua tabel `bm` terisi, termasuk
`rating_config`, `rank_point_levels`, `outbox_events`, dan `idempotency_keys`.

## Determinisme

- PRNG: SplitMix64 lokal di `main.nim` (bukan `std/random`), jadi hasilnya tidak
  bergantung versi Nim.
- UUID: fungsi `uuidFor(seed, namespace, index)` — UUIDv4 secara bentuk, tetapi
  diturunkan dari seed dan indeks, bukan `gen_random_uuid()`.
- Waktu: hanya `dateAt`/`stampAt` dari epoch tetap; tidak ada `now()` yang
  dibiarkan ke default kolom.
- Urutan baris tetap; tidak ada iterasi tabel hash.

Verifikasi cepat:

```sh
.cache/bin/fixtures --seed 7 --out /tmp/fx-a
.cache/bin/fixtures --seed 7 --out /tmp/fx-b
shasum -a 256 /tmp/fx-a/v1-fixtures.sql /tmp/fx-b/v1-fixtures.sql
```

## Integrasi task runner (belum dikerjakan)

`task.d/dev-v1.sh` masih memakai `ops/dev/v1/seed.sql`. Agar `./task dev-v1`
memakai generator ini, perlu entri baru di `task` (dispatcher dimiliki lane
platform) dan skrip `task.d/fixtures.sh`; keduanya sengaja tidak diubah di T-099.
