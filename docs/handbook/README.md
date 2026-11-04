# Handbook

Dokumen di folder ini menjelaskan **runtime v2** (backend Nim + frontend React) yang ada
di repo hari ini. Dokumen historis diberi label sendiri dan tidak boleh dipakai sebagai
panduan implementasi.

## Start Here

- [current-status.md](current-status.md) — kondisi repo, testing, infrastruktur (pintu
  masuk tercepat)
- [product-overview.md](product-overview.md) — deskripsi produk & area fitur
- [architecture.md](architecture.md) — arsitektur Nim/React, kontrak, auth, WebSocket
- [backend-go-decision.md](backend-go-decision.md) — **historis**: ADR Go v1 (2026-08-11),
  sudah digantikan rewrite Nim

## Reference

- [data-model.md](data-model.md) — skema database `bm2`, tabel, constraint, config
- [features-and-routes.md](features-and-routes.md) — rute web + 74 operasi API
- [roadmap.md](roadmap.md) — yang sudah ada & prioritas berikutnya
- [revamp-grand-plan.md](revamp-grand-plan.md) — **arsip v1**: desain granular live
  (Go/`bm`), tidak berlaku untuk v2
- [design-system.md](../design-system.md) — warna, tipografi, komponen, token

## Rencana & arsip

- [`../plan/`](../plan/README.md) — rencana rewrite v2 (BRD/PRD/TECH-SPEC/BACKLOG),
  dibekukan 2026-11-03
- [`../backend/`](../backend/README.md) — **arsip** migrasi SQL v1 `000013`–`000023`
  (skema `bm`), bukan skema aktif
- [`../audits/`](../audits/) — catatan audit (bila ada)
- [`../superpowers/`](../superpowers/) — design spec per fitur (arsip)
- Dokumen era Apps Script/Supabase sudah dihapus; tersedia di git history
  (`git log --all -- docs/`).
