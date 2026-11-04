# Gerbang perubahan kontrak (T-016)

Status: implementasi T-016. Rujukan: `BACKLOG.md:75`, `TECH-SPEC.md:500-505`,
`packages/contracts/openapi/README.md`, `.github/workflows/ci.yml:81`.

Dokumen ini menjelaskan kapan `packages/contracts/openapi/CONTRACT.sha256` berubah,
cara meregenerasinya, apa yang diperiksa gate, dan aturan pencatatan perubahan di
`CHANGELOG-frozen.md`.

## 1. Berkas yang dijaga

Enam berkas, dua di antaranya ditulis tangan
(`tools/contract-gen/fingerprint.nim:9-15`):

| Berkas | Pemilik | Boleh diedit tangan? |
|---|---|---|
| `packages/contracts/openapi/core.yaml` | T-008a | ya |
| `packages/contracts/openapi/community.yaml` | T-008b | ya |
| `packages/contracts/openapi/api.yaml` | generator | tidak |
| `apps/api/src/routes_gen.nim` | generator | tidak |
| `packages/web-client/src/api.ts` | generator | tidak |
| `packages/contracts/openapi/CONTRACT.sha256` | generator | tidak |

Selain task kontrak, tidak ada task lain yang menyentuh berkas generated
(`BACKLOG.md:26`).

## 2. Kapan hash berubah

Isi `CONTRACT.sha256` adalah SHA-256 dari **byte berkas**, bukan dari AST
(`tools/contract-gen/fingerprint.nim:38-53`). Karena itu:

| Perubahan | Efek pada `CONTRACT.sha256` |
|---|---|
| Edit `core.yaml`/`community.yaml` — termasuk komentar, urutan kunci, spasi | entri `spec` untuk berkas itu berubah |
| Perubahan semantik (operasi, path, status, bentuk body) | entri `spec` berubah; `api.yaml`, `routes_gen.nim`, dan `api.ts` ikut berubah setelah regenerate |
| Edit `tools/contract-gen/{gen,emit_nim,emit_ts,fingerprint}.nim` | output generated bisa berubah tanpa spec berubah; hash tetap wajib diperbarui |
| Tambah/hapus operasi | baris `operations` berubah; generator menolak jumlah selain **74** (`tools/contract-gen/gen.nim:82-83`) |

Angka 74 adalah kondisi sekarang (`packages/contracts/openapi/CONTRACT.sha256:7`).
Perpindahan 73 → 74 dicatat di `CHANGELOG-frozen.md:25` (operasi
`GET /c/{slug}/sessions/{id}/standings`).

## 3. Langkah regenerate

Semua perintah di bawah ada di `task.d/`; tidak ada perintah lain yang diperlukan.

1. Edit hanya `core.yaml` dan/atau `community.yaml`.
2. `./task contract-gen` — menulis ulang `api.yaml`, `routes_gen.nim`, `api.ts`,
   dan `CONTRACT.sha256` (`task.d/contract-gen.sh:10-11`,
   `tools/contract-gen/gen.nim:93-105`).
3. `./task contract-check` — fingerprint dan berkas generated harus cocok dengan
   spec (`task.d/contract-check.sh:14-17`).
4. Commit edit spec **bersama** berkas generated dan diff `CONTRACT.sha256` dalam
   satu commit. Diff itulah rekaman perubahan kontrak yang dibaca reviewer.
5. Catat niatnya di `CHANGELOG-frozen.md` (§5).

`./task contract-gen --check` menjalankan generator tanpa menulis apa pun: ia
membandingkan berkas generated **dan** `CONTRACT.sha256` dengan hasil generate,
tetapi tidak memberi laporan per-entri seperti tahap 1
(`tools/contract-gen/gen.nim:68`, `:93-101`).

Yang **tidak** boleh dilakukan: mengedit `CONTRACT.sha256` atau berkas generated
dengan tangan, dan memulihkan fingerprint lewat
`git checkout -- packages/contracts/openapi/CONTRACT.sha256` untuk membungkam
gate. Kegagalan gate berarti pohon kerja dan rekaman tidak sepakat, bukan bahwa
rekamannya salah.

## 4. Apa yang diperiksa gate

`./task contract-check` menjalankan dua tahap berurutan
(`task.d/contract-check.sh:14-17`):

**Tahap 1 — fingerprint (`tools/contract-gen/check.nim`).** Gate menghitung ulang
digest dari isi pohon sekarang dan membandingkannya dengan yang tercatat:

- jumlah operasi harus sama dengan baris `operations` (`check.nim:68-73`);
- setiap entri `spec` dan `generated` yang diharapkan harus ada dan cocok
  (`check.nim:74-90`);
- entri yang tercatat tetapi tidak lagi bagian dari kontrak dilaporkan juga
  (`check.nim:91-93`).

Bila ada selisih, gate keluar dengan status ≠ 0 dan mencetak
`contract-check: <path> is stale`, satu baris per entri yang berbeda, lalu
`run ./task contract-gen ...` (`check.nim:95-99`). Bila bersih:
`contract-check: ok (74 operations, 5 fingerprint entries)`.

**Tahap 2 — byte-exact (`task.d/contract-gen.sh --check`).** Generator dijalankan
ulang dan setiap artefak dibandingkan byte-per-byte; selisih apa pun dilaporkan
sebagai `contract-gen: stale <path>`, lalu
`generated files differ; run ./task contract-gen` (`gen.nim:95-101`). Tahap ini
menangkap berkas generated yang diedit tangan atau tertinggal setelah spec
berubah. Generator juga menolak `operationId` ganda (`gen.nim:85-87`) dan path
ganda antar dua spec (`gen.nim:30-33`).

Batas gate: ia memverifikasi **kecocokan**, bukan kebenaran semantik. Handler yang
berperilaku lain dari kontraknya tidak tertangkap di sini; itu tugas mock API
(T-015), parity harness (T-012/T-071), dan tes handler. Gate juga tidak menyentuh
DB — `./task check` sengaja tidak menjalankannya (`task.d/check.sh`), sedangkan
`./task ci` dan job `contract` di CI menjalankannya
(`task.d/ci.sh:8-10`, `.github/workflows/ci.yml:62-81`).

## 5. Aturan pencatatan di `CHANGELOG-frozen.md`

Perubahan kontrak adalah kelas C2: task baru + bump hash kontrak + satu review
pass (`reviews/round-5-pm.md:127`). Diff digest memberi tahu **apa** yang berubah;
`CHANGELOG-frozen.md` memberi tahu **mengapa**.

Setiap perubahan kontrak wajib menambah satu baris dengan format
`YYYY-MM-DD | berkas | jenis | alasan` (`CHANGELOG-frozen.md:6`), menyebut operasi
atau field yang berubah dan keputusan yang mendasarinya. Contoh yang sudah ada:
`CHANGELOG-frozen.md:25` (73 → 74, operasi `standings`) dan
`CHANGELOG-frozen.md:22` (penyelarasan status respons tanpa perubahan operasi).

Aturan tambahan:

- Perubahan yang hanya menyelaraskan metadata (status respons, deskripsi) tetap
  dicatat; yang berubah adalah perilaku yang dijanjikan, bukan hanya bentuk file.
- Bila perubahan kontrak ikut mengubah dokumen beku, hash di `FROZEN.md:13-19`
  harus diperbarui dalam commit yang sama dan baris changelog menyebutkannya
  (`FROZEN.md:54-55`).
- Perubahan kontrak yang tidak disertai baris changelog dianggap tidak
  dideklarasikan, walaupun gate hijau — gate hanya melihat digest.

## 6. Checklist

- [ ] Hanya `core.yaml`/`community.yaml` yang diedit.
- [ ] `./task contract-gen` dijalankan; diff `CONTRACT.sha256` ikut di commit.
- [ ] `./task contract-check` hijau.
- [ ] Baris `CHANGELOG-frozen.md` ditambahkan (tanggal, berkas, jenis, alasan).
- [ ] Bila dokumen beku tersentuh, hash `FROZEN.md` diperbarui di commit yang sama.

## Catatan

`packages/contracts/openapi/README.md:17` dan `:27` masih menulis 73 operasi dan
belum diperbarui setelah operasi `standings` masuk. Angka yang berlaku adalah 74
(`packages/contracts/openapi/CONTRACT.sha256:7`,
`tools/contract-gen/gen.nim:82`). Berkas itu tidak diubah di sini karena di luar
cakupan T-016.
