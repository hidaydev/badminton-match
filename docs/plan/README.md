# Rencana Rewrite Backend — Majadu v2 (Nim)

Direktori ini berisi rencana lengkap penggantian backend Go (`apps/api`) dengan
Nim, plus rework frontend yang mengikutinya. Semua pekerjaan berjalan **lokal**;
tidak ada push sampai R4 dinyatakan stabil.

> **Istilah.** `v1` = backend Go yang sekarang berjalan di repo ini. `v2` = backend
> Nim penggantinya, **di repo ini juga**. `majadu` adalah proyek terpisah dan tidak
> disentuh (O-1).

Tanggal rencana: 2026-11-03
Status: draft untuk review pemilik (belum ada kode produksi yang berubah)

---

## Urutan membaca

| # | Dokumen | Untuk siapa | Isi |
|---|---------|-------------|-----|
| 1 | [`BRD.md`](BRD.md) | pemilik | kenapa, tujuan bisnis, risiko, definisi sukses, keputusan final |
| 2 | [`PRD.md`](PRD.md) | pemilik + FE | persona, rilis R0–R4, 63 requirement ber-ID, NFR, perubahan UX |
| 3 | [`TECH-SPEC.md`](TECH-SPEC.md) | semua engineer | stack, layout, database `bm2`, kontrak, keamanan, CI/CD, parity, risiko |
| 4 | [`BACKLOG.md`](BACKLOG.md) | agen eksekusi | 83 task dengan `Depends`/`Owns`/acceptance, graf, pembagian agen |
| 5 | [`CROSS-CHECK.md`](CROSS-CHECK.md) | reviewer | 19 klaim diuji ke sumber, 9 putaran konsistensi, 3 review independen |
| 6 | [`REVIEW-scrum.md`](REVIEW-scrum.md) | reviewer | audit dependency, tabrakan file, gap, DoR/DoD |
| 7 | [`memos/`](memos/) | referensi | 6 memo ahli: stack, security, data, API, CI/CD, QA |
| 8 | [`EXECUTION.md`](EXECUTION.md) | pelaksana | prasyarat terverifikasi, urutan bootstrap, template prompt agen, protokol merge |
| 9 | [`reviews/`](reviews/) | reviewer | tiga audit independen: executability, consistency, adversarial |

Bila hanya punya 10 menit: baca `BRD.md` §4–§9, lalu `BACKLOG.md` §0–§2.

---

## Ringkasan keputusan

| Keputusan | Pilihan | Alasan singkat |
|-----------|---------|----------------|
| Lokasi rewrite | repo ini | majadu v2 tidak disentuh (O-1) |
| Kontrak API | boleh berubah; 60 operasi | FE ikut dikerjakan (O-2) |
| Auth | Google OIDC untuk **semua penulis**; tautan hanya baca | tidak ada jalur tulis anonim (O-3, O-9) |
| Multi-komunitas | satu instance, `community_id` + FK komposit, poin per komunitas | skema, auth, routing berubah (O-13..O-16) |
| Frontend | React 19 + Vite + Tailwind 4, **dibekukan** | tidak ada rewrite Svelte (O-17) |
| Parameter | semua angka bisnis di DB, berlapis platform → komunitas | tanpa default di kode, tanpa deploy (O-18, O-19) |
| P0 | diperbaiki sekali di Nim | keputusan pemilik (O-4) |
| Skema | `bm2` baru, `bm` nol DDL | utang v1 tidak bisa dibetulkan di tempat |
| Realtime | WebSocket | Mummy tidak bisa SSE |
| Kontrak | OpenAPI tulis tangan + codegen | handler hilang = error kompilasi |
| DB dev | PostgreSQL lokal (Homebrew 18.6, sudah berjalan) + template DB | nol risiko ke produksi |
| Cutover | pra-impor ke `bm2`, lalu satu push | v2 live tanpa jendela data kosong (O-10) |
| Rilis | SemVer dari commit, mulai `2.0.0`, tag SSH-signed | riwayat rilis bisa direproduksi (O-24, O-25) |
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

## Keputusan pemilik (2026-11-03)

| Pertanyaan | Jawaban | Dampak dokumen |
|---|---|---|
| Jendela P0 terbuka | diterima apa adanya, tanpa kontrol tambahan | `TECH-SPEC` §7.5, `ADR-011` |
| Penonton menulis | tidak, `view_code` read-only | `PRD` SES-02/03 |
| Host tanpa login | tidak, semua penulis login Google | `edit_code` dihapus; `TECH-SPEC` §7.3, `BACKLOG` T-024/T-030 |
| Impor data v1 | rilis kosong, impor setelah stabil | `TECH-SPEC` §10 |
| Verifikasi RS256 | modul binding OpenSSL | `ADR-009` diterima, task T-084 |
| Peran `member` | R2 | `PRD` R2, task T-048 |
| Multi-komunitas | masuk repo ini: `community_id` + FK komposit, poin per komunitas, akun global | `TECH-SPEC` §4/§5, task T-090..T-095 |
| Frontend | React 19 + Vite + Tailwind 4 dibekukan | tidak ada rewrite Svelte (O-17) |
| Parameter | semua angka bisnis dibaca dari DB, berlapis platform → komunitas | `TECH-SPEC` §4A, task T-096..T-098 |
| Database baru | `bm2` sebagai database terpisah + role `bm2_app` | `TECH-SPEC` §4 (O-20) |
| Database | **database baru `bm2`** (bukan schema di `bm`), role `bm2_app` terpisah | `bm` nol DDL (O-20) |

Tidak ada pertanyaan terbuka. Perubahan berikutnya yang menyentuh kontrak harus
lewat T-016 (`contract-change.md`).
