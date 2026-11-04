# apps/api — Majadu API (Nim)

Backend Majadu versi v2. Menggantikan server Go v1; keputusan dan konsekuensinya
di `docs/plan/ADR-011.md`. Kontrak HTTP-nya
[`packages/contracts/openapi/`](../../packages/contracts/openapi/README.md),
bukan dokumen terpisah di folder ini.

## Stack

- Nim 2.4.0, `mummy` sebagai server HTTP (thread pool, WebSocket)
- PostgreSQL 18, skema per domain (`platform`, `community`, `player`, `session`,
  `tournament`, `rating`, `achievement`, `auth`, `account`); role `bm2_app` untuk
  runtime, `bm2_owner` untuk migrasi, `bm2_etl` untuk ETL
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

`packages/contracts/openapi/{core,community}.yaml` adalah sumbernya: **75 operasi**
(lihat `CONTRACT.sha256`). Route hasil generate wajib punya handler; kompilasi
gagal bila ada yang hilang.

## Gate

```sh
./task check            # nim check, unit test, archcheck (tanpa database)
./task test             # + integration (butuh MAJADU_PG_DSN)
./task coverage         # baris per modul, ratchet terhadap coverage-baseline.json
./task parity verify    # korpus v1 beku (71 kasus, 48 rute)
```

Migrasi: 16 berkas (`db/migrations/0001`–`0016`). Config bisnis: 36 key di
`modules/platform/config/registry.nim`.

## v1 sudah dihapus

Sumber Go v1 (`cmd/`, `internal/`, `api/openapi.yaml`, `go.mod`, `go.sum`,
`Makefile`) dihapus di T-082, setelah image `localhost/majadu-api:v1-final`
menjadi jalur rollback. Konsekuensinya: v1 tidak bisa di-hotfix dari source lagi
selama 30 hari masa simpan image; perbaikannya masuk ke v2 atau rollback memakai
image apa adanya. Source-nya tetap bisa diambil dari riwayat git sebelum T-082.

Kontrak v1 yang dibekukan ada di `testdata/parity/v1/` (lihat README-nya) dan
tidak butuh source Go.
