# Docs

Dokumentasi proyek, dua lane:

1. **Handbook aktif** — cara kerja proyek hari ini
2. **Arsip** — dokumen historis. Arsip era Apps Script / Supabase dihapus 2026-08-15 dan
   tersedia di git history.

## Start Here

- [`handbook/README.md`](handbook/README.md) — index handbook
- [`handbook/current-status.md`](handbook/current-status.md) — kondisi sekarang, infrastruktur, testing
- [`handbook/backend-go-decision.md`](handbook/backend-go-decision.md) — ADR: Go menggantikan PostgREST (historis)

## What Lives Here

### `handbook/`

- [`product-overview.md`](handbook/product-overview.md) — deskripsi produk & area fitur
- [`architecture.md`](handbook/architecture.md) — arsitektur FE/BE, SSE catch-up, PWA Workbox
- [`data-model.md`](handbook/data-model.md) — SSOT tipe TS & skema Postgres `bm`
- [`features-and-routes.md`](handbook/features-and-routes.md) — peta rute & kapabilitas halaman
- [`current-status.md`](handbook/current-status.md) — status, infrastruktur, hasil test
- [`roadmap.md`](handbook/roadmap.md) — fase selesai & prioritas berikutnya
- [`backend-go-decision.md`](handbook/backend-go-decision.md) — ADR 2026-08-11 (historis)
- [`revamp-grand-plan.md`](handbook/revamp-grand-plan.md) — design doc granular live (sudah diimplementasikan)

### `backend/`

SQL migrasi `000013`–`000016` + daftarnya di [`backend/README.md`](backend/README.md).

### `superpowers/`

Design spec per fitur (arsip).

### `design-system.md`

Design tokens, tipografi, dan pola UI (Tailwind v4 `@theme`).

## Konvensi

- Dokumen yang mendeskripsikan runtime era lama (Supabase/PostgREST) dianggap obsolete —
  jangan dihidupkan kembali.
- Satu fakta satu tempat: skema DB di `data-model.md`, status & angka test di `current-status.md`,
  prioritas ke depan di `roadmap.md`.
- Detail historis (termasuk dokumen audit yang sudah dihapus) ada di git history (`git log --all -- docs/`).
