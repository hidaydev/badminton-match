# Pembekuan Rencana (O-43)

Gate perencanaan ditutup **2026-11-03**. Pembekuan berlaku efektif saat R0
(walking skeleton) lulus; hash di bawah adalah baseline yang harus tetap sama
sampai titik itu. Setelah R0, dokumen tidak dibuka lagi untuk putaran review baru.

## Baseline dokumen

Verifikasi dengan `shasum -a 256 docs/plan/<berkas>`; harus sama persis.

| Berkas | SHA-256 |
|---|---|
| `BRD.md` | `ac782e58369b3586837c5ab898879aa78ddab6b13b212f3bc08c9babb7774bd7` |
| `PRD.md` | `f4dc7137c9013646be849c9609c85734863cf7ae3a93f158c70aa77492e292ed` |
| `TECH-SPEC.md` | `132a935f37659301af139a521d68b14ef2740029e3aaad44d568165b0a73930f` |
| `BACKLOG.md` | `29f44c5d5f8d825c70fb675f829080c8ec3f2bbc97dca9022d9b13ab8e3836be` |
| `EXECUTION.md` | `9d47b00e35a8a844f8ecc16205b6fdd825885cb7ea0176b62f9a6f3fcca163ed` |
| `CROSS-CHECK.md` | `a974207cb0929cd313a1dd84a683b84c88b2e0488266c8916e0699fa80518b6f` |
| `README.md` | `43bb7acb617c253524e42fb78d5806846779a6eafeed199d8b5178c7783ef357` |

Commit pembekuan = commit yang memuat berkas ini; lihat
`git log -1 -- docs/plan/FROZEN.md`. `memos/` bersifat historis dan tidak di-hash.
`reviews/` juga tidak di-hash dan **tidak diterbitkan**: T-108 mengeluarkannya dari
riwayat publik bersama `docs/audits`.

## Angka yang dibekukan

| Hal | Jumlah |
|---|---|
| Task | 88 (termasuk T-008a/T-008b) |
| Requirement | 72 |
| Operasi API v2 | 74 |
| ADR | 31 (ADR-001..ADR-031) |
| Keputusan pemilik | O-1..O-43 |

Angka operasi dinaikkan 73 → 74 pada 2026-11-04 atas persetujuan pemilik
(operasi `getSessionStandings` untuk halaman ekspor); alasannya di
`CHANGELOG-frozen.md`. Dokumen beku lain tidak berubah dan hash di atas tetap.

Kedua checker harus bersih sebelum dan sesudah setiap perubahan yang diizinkan:

```
python3 .local/audit_plan.py
python3 .local/check2.py
```

## Yang boleh dan tidak boleh setelah beku

| Jenis perubahan | Boleh? | Prosedur |
|---|---|---|
| Perbaikan fakta yang salah (path, perintah, tipe, angka yang terbukti keliru) | ya | commit `docs(plan): fix ...`; catat di `CHANGELOG-frozen.md` |
| Klarifikasi acceptance yang ambigu, **hanya bila task belum dimulai** | ya | catat di `CHANGELOG-frozen.md`; tidak menambah cakupan |
| Menambah task, requirement, operasi, atau ADR | **tidak** | tunggu 2.1 |
| Mengubah keputusan O-* atau mengganti stack | **tidak** | hanya dengan persetujuan pemilik; itu berarti keluar dari pembekuan |
| Refactor kosmetik dokumen | tidak | tunda |
| Putaran audit/review menyeluruh baru | **tidak** | review per task saat implementasi, bukan perencanaan ulang |

Setiap perubahan pasca-beku wajib memperbarui hash di atas dalam commit yang sama
dan menambah satu baris di `CHANGELOG-frozen.md` (tanggal, berkas, alasan).

## Gate R0 (definisi lulus)

R0 belum selesai sampai semua baris ini benar:

- [x] `./task check` lulus, hangat ≤ 60 s, tanpa DB (14 s; 33 berkas archcheck).
- [x] `./task dev-db` membuat `bm2_dev` + `bm2_template`; `dbtools verify` bersih.
- [x] `./task contract-gen` menghasilkan tepat **74** operasi dan CI gagal bila
      hasil generate berbeda dari commit (`--check`).
- [x] Walking skeleton lewat HTTP: login stub → pilih komunitas → buat sesi →
      share → `GET /s/{code}` dan `GET /s/{code}/rankings`
      (satu perintah: `./task r0-demo`).
- [x] Graceful shutdown terbukti (`SIGTERM` menunggu `MAJADU_DRAIN_MS`): 700 ms
      in-flight selesai 200, proses keluar 0 setelah ~1,08 s.
- [x] `./task ci` hijau pada satu commit; tidak ada test yang di-skip karena DB
      tidak ada.
- [x] Demo singkat + retro dicatat di `CHANGELOG-frozen.md`.

Urutan build R0: **T-001 → T-018 → T-007**, lalu **T-003/T-004** paralel,
kemudian T-002, T-005, T-006a–e, T-008a/b, T-009, T-010, T-011, T-085.

## Setelah R0

Tidak ada lagi fase perencanaan. Yang tersisa: implementasi per task sesuai
`BACKLOG.md`, review kode per task, dan gate rilis. Temuan yang tidak memblokir
implementasi masuk backlog 2.1 — bukan alasan membuka putaran dokumen baru.
