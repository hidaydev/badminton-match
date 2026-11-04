# apps/api — Majadu API (Nim)

Backend Majadu versi v2. Menggantikan server Go v1; keputusan dan konsekuensinya
di `docs/plan/ADR-011.md`. Kontrak HTTP-nya
[`packages/contracts/openapi/`](../../packages/contracts/openapi/README.md),
bukan dokumen terpisah di folder ini.

## Stack

- Nim 2.2, `mummy` sebagai server HTTP (thread pool, WebSocket)
- PostgreSQL, skema `majadu_v2` (role `bm2_app` untuk runtime, `bm2_owner` untuk migrasi)
- Satu cookie sesi `HttpOnly`; tidak ada token di klien
- Route dihasilkan dari kontrak (`routes_gen.nim`); handler diverifikasi saat kompilasi

## Struktur

```
src/main.nim            # entrypoint: baca env, buka db, pasang handler
src/server.nim          # kontrak proses (port, drain, timeout) — tanpa default tersembunyi
src/app.nim             # dispatch route, handler, audit
src/routes_gen.nim      # DIBANGKITKAN dari kontrak; jangan diedit
src/auth_middleware.nim # 401/403/404 sesuai matriks peran
src/community_context.nim
src/security_headers.nim
src/live.nim            # hub WebSocket sesi & share
src/ratelimit.nim
tests/                  # unit + integration + security
```

Modul domain ada di [`modules/`](../../modules), pustaka bersama di
[`shared/platform-lib/`](../../shared/platform-lib), migrasi dan seed di
[`db/`](../../db).

## Environment

Tanpa nilai default untuk hal yang menentukan perilaku: proses menolak start
bila salah satu wajib tidak ada.

| Variabel | Wajib | Keterangan |
|---|---|---|
| `MAJADU_PG_DSN` | ya | DSN Postgres |
| `MAJADU_PORT` | ya | port listen |
| `MAJADU_DRAIN_MS` | ya | jendela drain saat SIGTERM (boleh 0) |
| `MAJADU_SHUTDOWN_TIMEOUT_MS` | tidak | batas keras shutdown, bawaan 30000 |
| `OIDC_{AUTHORIZE_URL,TOKEN_URL,JWKS_URL,ISSUER,CLIENT_ID,REDIRECT_URI}` | ya | penyedia identitas |
| `SHARE_CODE_KEYS`, `SHARE_CODE_ACTIVE_KEY_ID` | ya | keyring tautan berbagi |
| `MAJADU_BOOTSTRAP_OWNER_EMAIL` | tidak | pemilik platform pertama |
| `CUTOVER_SNAPSHOT_SHA256` | tidak | snapshot yang diharapkan; `/readyz` menolak yang lain |

`MAJADU_TEST_ROUTES=1` hanya untuk suite, bukan untuk deployment.

## Menjalankan

```sh
./task dev            # API :8080 + OIDC stub :19090, migrasi + seed bm2_dev
./task dev --watch    # sama, rebuild + restart saat .nim berubah
./task build          # binary release di .cache/<worktree>/bin/majadu-api
./task test           # butuh MAJADU_PG_DSN
```

Health: `GET /healthz` hidup selama proses hidup; `GET /readyz` memeriksa
database, skema, dan snapshot, dan membalas `503` bila salah satunya tidak siap.

## Kontrak

```sh
./task contract-gen     # tulis ulang routes_gen.nim, client TS, fingerprint
./task contract-check   # gagal bila spesifikasi dan hasil generate berbeda
```

`packages/contracts/openapi/{core,community}.yaml` adalah sumbernya; angka
operasi yang dibekukan dicatat di `docs/plan/FROZEN.md`.

## Sisa v1

`cmd/`, `internal/`, `go.mod`, `go.sum`, `api/openapi.yaml`, dan `Makefile` di
folder ini adalah sumber Go v1 yang belum dihapus. Ia tidak dipakai build,
kontrak, maupun deploy; penghapusannya menunggu cutover (T-060/T-065) supaya
perbandingan v1 masih mungkin dilakukan.
