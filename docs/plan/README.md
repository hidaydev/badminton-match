# Rencana Rewrite Backend — Majadu v2 (Nim)

Direktori ini berisi rencana lengkap penggantian backend Go (`apps/api`) dengan
Nim, plus rework frontend yang mengikutinya. Semua pekerjaan berjalan **lokal**;
tidak ada push sampai R4 dinyatakan stabil.

Tanggal rencana: 2026-11-03
Status: draft untuk review pemilik (belum ada kode produksi yang berubah)

---

## Urutan membaca

| # | Dokumen | Untuk siapa | Isi |
|---|---------|-------------|-----|
| 1 | [`BRD.md`](BRD.md) | pemilik | kenapa, tujuan bisnis, risiko, definisi sukses, keputusan final |
| 2 | [`PRD.md`](PRD.md) | pemilik + FE | persona, rilis R0–R4, 41 requirement ber-ID, NFR, perubahan UX |
| 3 | [`TECH-SPEC.md`](TECH-SPEC.md) | semua engineer | stack, layout, skema `bm2`, kontrak, keamanan, CI/CD, parity, risiko |
| 4 | [`BACKLOG.md`](BACKLOG.md) | agen eksekusi | 60 task dengan `Depends`/`Owns`/acceptance, graf, pembagian agen |
| 5 | [`CROSS-CHECK.md`](CROSS-CHECK.md) | reviewer | 19 klaim diuji ke sumber, 10 konsistensi, koreksi audit |
| 6 | [`REVIEW-scrum.md`](REVIEW-scrum.md) | reviewer | audit dependency, tabrakan file, gap, DoR/DoD |
| 7 | [`memos/`](memos/) | referensi | 6 memo ahli (2.167 baris): stack, security, data, API, CI/CD, QA |

Bila hanya punya 10 menit: baca `BRD.md` §4–§9, lalu `BACKLOG.md` §0–§2.

---

## Ringkasan keputusan

| Keputusan | Pilihan | Alasan singkat |
|-----------|---------|----------------|
| Lokasi rewrite | repo ini | majadu v2 tidak disentuh (O-1) |
| Kontrak API | boleh berubah | FE ikut dikerjakan (O-2) |
| Auth | Google OIDC + `edit_code` untuk guest | menghapus token admin statis (O-3) |
| P0 | diperbaiki sekali di Nim | keputusan pemilik (O-4) |
| Skema | `bm2` baru, `bm` nol DDL | utang v1 tidak bisa dibetulkan di tempat |
| Realtime | WebSocket | Mummy tidak bisa SSE |
| Kontrak | OpenAPI tulis tangan + codegen | handler hilang = error kompilasi |
| DB dev | Podman lokal + template DB | nol risiko ke produksi |
| Parity | golden JSON + divergensi deklaratif | mencegah bug v1 ikut pindah |

---

## Cara memakai backlog dengan subagent

1. Ambil satu task dari `BACKLOG.md` yang **semua `Depends`-nya sudah selesai**.
2. Beri agen itu: ID task, isi baris tabel, dan path di kolom `Owns`.
3. Agen hanya boleh menulis di `Owns`-nya. Perubahan kontrak lewat T-016.
4. Selesai = acceptance lulus + `./task check` + `./task verify <modul>`.
5. Merge dilakukan orchestrator; agen tidak menyentuh `main` bersama.

Batas aman: **4 agen aktif**. Jalur kritis yang tidak boleh ditambah beban:
`T-004 → T-005 → T-006a` dan `T-008 → T-009`.

---

## Guardrail repo publik

- Tidak ada secret, token, IP asli, dump skema, atau data pribadi di direktori ini.
- Dump skema v1 ada di `.local/` (gitignored) dan hanya untuk pengembangan.
- Semua contoh konfigurasi memakai placeholder; nilai nyata hanya di VPS.
- `docs/plan/` boleh publik; kalau ragu, jangan tulis.

---

## Yang belum diputuskan pemilik

1. Berapa lama jendela P0-terbuka dapat diterima sebelum kontrol kompensasi dipasang?
2. Apakah penonton boleh menulis skor, atau baca saja?
3. Apakah host tanpa login tetap wajib ada setelah Google auth?
4. Impor data v1 pada rilis pertama, atau mulai kosong?
5. ADR-009: setuju menambah modul binding OpenSSL untuk verifikasi RS256?
6. Model `member` masuk R1 atau ditunda?

Jawaban atas enam hal ini mengubah isi `PRD.md` §4 dan `BACKLOG.md` §2–§3;
sebelum dijawab, rencana tetap draft.
