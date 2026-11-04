# Keputusan Arsitektur (historis): Backend Go v1

> **Status: HISTORIS — sudah digantikan rewrite Nim (v2).**
> Dokumen ini adalah catatan keputusan 2026-08-11, bukan panduan kerja. Backend yang
> berlaku hari ini adalah Nim di `apps/api/src/` (lihat
> [`architecture.md`](architecture.md)). Jangan menyalin path, skema, atau kontrak dari
> sini ke kode baru.

## Konteks saat keputusan diambil

Awal Agustus 2026 aplikasi masih memakai **Supabase/PostgREST + RPC SQL**. Logika bisnis
hidup di fungsi SQL `SECURITY DEFINER`, sementara frontend React memanggil RPC. Model itu
sulit diuji, diaudit, dan diberi rate limit; RLS juga tidak masuk akal tanpa login.

Keputusan saat itu: bangun backend **Go** (`majadu-api`) sebagai satu-satunya backend,
pindahkan logika dari SQL ke Go, lalu pensiunkan Supabase.

## Isi keputusan (ringkas)

| Topik | Keputusan v1 |
|---|---|
| Bahasa | Go 1.26, `net/http` + `pgx` |
| Database | Postgres VPS, schema `bm` (dev `bm_dev`) |
| Kontrak | Mirror snapshot lama; `PUT /sessions/{id}` dan `PUT /tournaments/{id}` sebagai bridge |
| Auth | Ditunda; admin memakai bearer token |
| Realtime | SSE (`/sessions/{id}/watch`) |
| Repo | Backend terpisah `majadu-api`, branch `main`/`dev` |
| Deploy | Build di VPS lewat webhook, quadlet, Caddy `/majadu` |

Hasilnya berjalan di produksi v1: ±48 rute, migrasi `000013`–`000023`, rating poin
menggantikan Glicko, dan SSE untuk sesi live.

## Kenapa digantikan

Pada 2026-11-03 diputuskan rewrite **Nim v2 di repo yang sama**. Alasan yang tercatat di
`docs/plan/`:

- Kontrak perlu berubah untuk multi-komunitas, auth semua penulis, dan operasi granular.
- Skema `bm` tidak boleh diubah lagi (utang v1); v2 memakai database baru `bm2`.
- Mummy tidak menyediakan SSE → v2 memakai WebSocket.
- Kontrak-dulu (OpenAPI tulis tangan + codegen) lebih murah dijaga daripada mirror
  snapshot.
- Satu bahasa untuk backend dan tooling, dengan config bisnis di database.

Rencana lengkap dan beku: [`../plan/TECH-SPEC.md`](../plan/TECH-SPEC.md),
[`../plan/BACKLOG.md`](../plan/BACKLOG.md).

## Yang sudah dihapus

Kode Go v1 (`apps/api/cmd/`, `apps/api/internal/`, `apps/api/api/`, `go.mod`,
`go.sum`, `Makefile`) dihapus di T-082. Rollback memakai image
`localhost/majadu-api:v1-final` selama masa simpannya; source-nya tetap bisa diambil
dari riwayat git sebelum T-082. Kontrak v1 yang dibekukan ada di
`testdata/parity/v1/`.

## Pelajaran yang tetap berlaku

1. Server harus memegang invariant (skor, poin, otorisasi), bukan klien.
2. Concurrency harus eksplisit (`If-Match`/versi), bukan last-write-wins.
3. Satu aturan satu tempat; jangan menduplikasi validasi di FE dan BE.
4. Migrasi dan kontrak harus punya checksum/gate agar perubahan terlihat di review.

## Rujukan yang berlaku

- Arsitektur runtime: [`architecture.md`](architecture.md)
- Status & infrastruktur: [`current-status.md`](current-status.md)
- Skema data: [`data-model.md`](data-model.md)
- Rute & operasi: [`features-and-routes.md`](features-and-routes.md)
