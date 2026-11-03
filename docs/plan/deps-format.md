# `deps.lock` format

Status: implementasi T-002. Rujukan: `TECH-SPEC.md` §2, `BACKLOG.md` T-002,
`reviews/final-r0.md` butir 11.

`deps.lock` adalah satu-satunya sumber kebenaran versi toolchain, paket Nim, dan
alat gate non-Nim. Tidak ada `nimble.lock`: dependensi dipasang manual, lalu
`./task deps-check` memverifikasi bahwa isi yang benar-benar terpasang sama dengan
yang tercatat. Timestamp tidak pernah dibandingkan.

## 1. Bentuk berkas

```text
# komentar diawali '#'
tree <sha256>
<name> <version> <source> <sha256>
...
```

- **Satu entri per baris, tepat empat field**, dipisah satu spasi. Field tidak boleh
  mengandung spasi.
- `name` unik. Duplikat menggagalkan `deps-check`.
- `version` adalah versi yang terpasang. Bila alat tidak punya metadata versi
  (mis. font), tulis `-`; **jangan mengarang nomor**. Alat yang tidak terpasang
  ditulis `absent` dan `sha256`-nya `-`.
- `sha256` adalah digest isi. `-` berarti entri tidak punya isi untuk di-hash
  (toolchain, browser, npm package).
- Baris `tree` wajib ada sekali, di bagian atas. Komentar dan urutan baris tidak
  memengaruhi `tree`; entri diurutkan `LC_ALL=C` saat dihitung.

## 2. `source` — skema

| Skema | Arti | Cara verifikasi |
|---|---|---|
| `nimble:<url>` | paket Nim di `$NIMBLE_DIR/pkgs2` (`~/.nimble/pkgs2` default) | direktori `name-version-*` harus ada tepat satu, isinya di-hash |
| `nimble:<url>@<commit>` | sama, tetapi commit wajib cocok dengan `vcsRevision` di `nimblemeta.json` | idem + cek commit |
| `repo:<path relatif>` | berkas atau direktori di repo | berkas: sha256 byte; direktori: digest isi |
| `toolchain:<perintah>` | kompiler/alat di `PATH` (`nim`, `gcovr`, `lcov`) | `version` `absent` → perintah harus **tidak** ada; selain itu versi dibandingkan |
| `npm:<paket>` | paket npm dari workspace FE | `apps/web/node_modules/<paket>/package.json` (`version` → `version`) |
| `playwright-browser:<name>` | build browser Playwright `<name>-<version>` | direktori `<browser-cache>/<name>-<version>/INSTALLATION_COMPLETE` |

Browser cache: `PLAYWRIGHT_BROWSERS_PATH` bila diset, selain itu
`~/Library/Caches/ms-playwright` (macOS) atau `~/.cache/ms-playwright` (lain).

Skema tidak dikenal = kegagalan, bukan entri yang dilewati.

## 3. Algoritma digest

**Paket / direktori** (`nimble:` dan `repo:` yang menunjuk direktori):

```text
untuk setiap berkas biasa di bawah direktori, diurutkan LC_ALL=C menurut path relatif:
    <path-relatif>\n
    <sha256 isi berkas>\n
sha256 dari gabungan byte di atas
```

`nimblemeta.json` **dikecualikan**: array `files` di dalamnya mengikuti urutan
filesystem saat instalasi, sehingga hash bisa berbeda antar mesin. Timestamp,
mode, owner, dan isi `.git` tidak pernah masuk digest.

**Berkas tunggal** (`repo:` yang menunjuk berkas): sha256 byte berkas.

**`tree`**: gabungan baris entri kanonik (`name version source sha256`) yang
diurutkan `LC_ALL=C`, masing-masing diakhiri `\n`, lalu di-hash sha256. Karena
setiap baris memuat digest isi, `tree` ikut berubah bila satu berkas paket,
satu versi alat, atau satu font berubah. `tree` **tidak** dihitung dari isi
mentah semua paket, jadi menambah entri baru selalu mengubah `tree`.

## 4. Memperbarui

1. Pasang/ubah dependensi secara manual (`nimble install`, `pnpm install`,
   `pnpm exec playwright install`).
2. Tambahkan entri baru dengan `sha256` sementara `-` (atau ubah `name`/`version`)
   di `deps.lock`.
3. Jalankan `./task deps-check --print`. Keluarannya: baris `tree <sha256>` dan
   seluruh entri kanonik dengan digest hasil hitung ulang. Perintah ini tidak
   menulis berkas.
4. Salin nilai `sha256` yang berubah dan baris `tree` ke `deps.lock`
   (komentar dan pengelompokan tidak disentuh).
5. `./task deps-check` harus lulus.

`--print` hanya membaca alat yang dipasang; entri yang tidak bisa di-resolve
dilaporkan ke stderr, tidak ikut tercetak, dan membuat exit ≠ 0 — keluaran yang
bolong tidak boleh disalin diam-diam.

## 5. Perilaku `deps-check`

- `./task deps-check` → exit 0 dan `deps-check: ok` bila semua entri cocok dan
  `tree` sama.
- Kegagalan apa pun → exit 1, dengan blok `lock:`/`computed:` per entri yang
  berbeda, lalu jumlah masalah. Contoh:

  ```text
  deps-check: entry differs: mummy
    lock:     mummy 0.4.8 nimble:https://github.com/guzba/mummy 3e3a...
    computed: mummy 0.4.8 nimble:https://github.com/guzba/mummy 91bd...
  deps-check: tree hash differs
    lock:     045c62f915c5e6563a1ecedff545cb50a3999adebcb37a4f6feaa6c3ac334261
    computed: 4ed30fdd0e3f4f2df3ac5e18c1c38bae5b1641b479b94a848707143d7d9716a1
  deps-check: 2 problem(s); update deps.lock (docs/plan/deps-format.md)
  ```

- Entri `absent` yang kemudian terpasang, atau versi alat yang naik (Nim,
  Playwright, revisi browser), dilaporkan sebagai drift dan **harus** disetujui
  lewat pembaruan `deps.lock`. Itu memang tujuannya: gate T-011 dan T-072 membaca
  berkas ini, jadi perubahan versi tidak boleh terjadi diam-diam.
- Alat yang tidak terpasang (mis. `node_modules` belum ada) menggagalkan
  pemeriksaan entri tersebut, bukan dilewati. Bila ada entri yang tidak bisa
  di-resolve, perbandingan `tree` dilewati karena digest atas himpunan entri yang
  tidak lengkap tidak bermakna; kegagalan entri sudah membuat exit ≠ 0.

## 6. Batas yang diketahui

- Digest isi paket hanya membuktikan "isi direktori terpasang sama dengan yang
  dipin", bukan bahwa URL di `source` benar; URL diambil dari `nimblemeta.json`
  saat pertama kali ditulis ke lock.
- `deps-check` tidak memeriksa paket yang terpasang tetapi tidak tercatat di
  `deps.lock` (tidak ada klaim kelengkapan seluruh `pkgs2`). Yang dijaga adalah
  setiap entri yang tercatat.
