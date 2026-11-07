# Docs

Dokumentasi proyek, tiga lane:

1. **Handbook** — cara kerja proyek hari ini (runtime v2: Nim + React).
2. **Operasi & privasi** — akses, insiden, retensi.
3. **Arsip** — dokumen historis; jangan dijadikan acuan runtime.

## Start Here

- [`handbook/README.md`](handbook/README.md) — index handbook
- [`handbook/current-status.md`](handbook/current-status.md) — kondisi sekarang, infrastruktur, testing
- [`handbook/architecture.md`](handbook/architecture.md) — arsitektur FE/BE, WebSocket, PWA
- [`handbook/data-model.md`](handbook/data-model.md) — skema database v2 (`bm2`) dan bentuk data API

## What Lives Here

### `handbook/`

- [`product-overview.md`](handbook/product-overview.md) — deskripsi produk & area fitur
- [`architecture.md`](handbook/architecture.md) — arsitektur FE/BE, kanal WebSocket, PWA
- [`data-model.md`](handbook/data-model.md) — skema Postgres v2, tenancy, migrasi
- [`features-and-routes.md`](handbook/features-and-routes.md) — peta rute web & 75 operasi API
- [`current-status.md`](handbook/current-status.md) — status, infrastruktur, hasil test
- [`roadmap.md`](handbook/roadmap.md) — fase selesai & prioritas berikutnya
- [`backend-go-decision.md`](handbook/backend-go-decision.md) — ADR 2026-08-11: Go menggantikan PostgREST (historis, sudah digantikan Nim)
- [`revamp-grand-plan.md`](handbook/revamp-grand-plan.md) — design doc granular live (sudah diimplementasikan)

### `ops/`

- [`operations.md`](ops/operations.md) — pemegang akses, format insiden lima bidang, pemeriksaan rutin
- [`release.md`](ops/release.md) — urutan rilis, kriteria keluar, aturan expand/contract, rollback `:prev`
- [`google-oauth.md`](ops/google-oauth.md) — client Google, redirect URI, secret, rotasi, dan uji login
- [`cutover.md`](ops/cutover.md) — runbook cutover v1 → v2, rehearsal D-3, rollback, dan konsekuensinya
- [`pre-push.md`](ops/pre-push.md) — hook yang menolak `docs/audit` dan `docs/plan/reviews` kembali ke repo publik
- [`../tools/rehearsal/README.md`](../tools/rehearsal/README.md) — harness rehearsal cutover + gate `timings.json`

### `privacy.md`

Data apa yang disimpan, dasar pemrosesan, retensi, dan apa yang dipertahankan saat
akun dianonimkan.

### `backend/`

Arsip migrasi SQL v1 `000013`–`000023` + daftarnya di [`backend/README.md`](backend/README.md).
Skema itu **tidak** dipakai v2; sumber kebenaran ada di `db/migrations/`.

### `superpowers/`

Design spec per fitur (arsip).

### `design-system.md`

Design tokens, tipografi, dan pola UI (Tailwind v4 `@theme`).

## Konvensi

- Dokumen yang mendeskripsikan runtime era lama (Supabase/PostgREST, Go v1) adalah
  arsip — jangan dihidupkan kembali sebagai acuan implementasi.
- Satu fakta satu tempat: skema DB di `data-model.md`, status & angka test di
  `current-status.md`, prioritas ke depan di `roadmap.md`.
- Dokumen internal (handbook, ADR, task) boleh bahasa Indonesia; kode dan komentar
  tetap bahasa Inggris.
- Detail historis ada di git history (`git log --all -- docs/`).
