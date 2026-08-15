# Docs

Dokumentasi proyek, terbagi dua lane:

1. **Handbook aktif** — cara kerja proyek hari ini
2. **Arsip** — dokumen historis (era Apps Script / Supabase) sudah dihapus
   2026-08-15; konteks historis tersedia di git history.

## Start Here

Mulai dari sini untuk kebenaran kondisi sekarang:

- [`handbook/README.md`](handbook/README.md)
- [`handbook/current-status.md`](handbook/current-status.md)
- [`handbook/backend-go-decision.md`](handbook/backend-go-decision.md)

## What Lives Here

### `handbook/`

Dokumentasi aktif:

- product overview
- architecture & route map
- data model (`bm`/`bm_dev`, diakses via backend Go `majadu-api`)
- backend decision record
- roadmap

### `design-system.md`

Design tokens, tipografi, dan pola UI (Tailwind v4 `@theme`).

## Konvensi

- Dokumen yang mendeskripsikan runtime era lama (Supabase/PostgREST) dianggap
  obsolete dan dihapus — jangan dihidupkan kembali.
- Detail migrasi/arsip ada di git history (`git log --all`).
