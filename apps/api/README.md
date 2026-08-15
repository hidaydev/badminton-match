# majadu-api

Backend Go untuk Majadu — menggantikan PostgREST RPC (Supabase) sebagai satu-satunya
backend. Lihat keputusan arsitektur di repo `badminton-match`:
`docs/handbook/backend-go-decision.md`.

## Stack

- Go 1.26, stdlib `net/http` (Go 1.22+ routing) — tanpa framework HTTP
- `pgx/v5` untuk Postgres (schema `bm_dev` / `bm`)
- Kontrak RESTful didokumentasikan di [`api/openapi.yaml`](api/openapi.yaml)

## Struktur

```
cmd/server/              # entrypoint
internal/config/         # env + godotenv (.env dev lokal) + validasi strict
internal/db/             # koneksi pool pgx
internal/domain/         # tipe CloudSnapshot + transform + validasi (di-port dari TS/SQL)
internal/store/          # akses DB: write-path session di Go, read-path fungsi SQL
internal/handler/        # HTTP handlers (REST)
internal/middleware/     # CORS, logging (slog), panic recovery, rate limit
internal/httperr/        # error envelope JSON konsisten
internal/build/          # versi binary (ldflags)
api/openapi.yaml         # kontrak REST resmi
```

> **SQL migrations TIDAK di repo GitHub** (sengaja — kode repo public).
> Tersimpan di VPS: `/srv/qouver/majadu/migrations/` (000001–000005).

## Endpoint (ringkas)

Base path produksi: `https://api.qouver.com/majadu` (prefix di-strip Caddy —
Go backend melihat path bersih tanpa prefix).

| Method | Path | Fungsi |
|---|---|---|
| `GET` | `/healthz` | liveness (infra, tanpa base) |
| `GET` | `/readyz` | readiness — ping DB (infra) |
| `GET` | `/version` | build info |
| `POST` / `GET` | `/sessions` | create / list |
| `GET` / `PATCH` / `DELETE` | `/sessions/{id}` | get / patch / delete |
| `POST` | `/sessions/{id}/lock` · `/unlock` | kunci / buka |
| `PUT` / `DELETE` | `/sessions/{id}/games/{key}` | set skor / hapus skor |
| `PATCH` | `/sessions/{id}/players/{pid}` | rename pemain |
| `PUT` | `/sessions/{id}/absent` | set absent |
| `POST` | `/sessions/{id}/swaps/{players\|teams\|slots}` | swap |
| `GET` / `POST` | `/players` | list / register pemain |
| `GET` | `/players/{name}/stats` | statistik karier |
| `POST` | `/tournaments` | buat tournament |
| `GET` / `PATCH` | `/tournaments/{id}` | get / update |

Concurrency: optimistic via header `If-Match: "v{n}"` / response `ETag`.

## Menjalankan

```bash
cp .env.example .env   # isi DATABASE_URL + MAJADU_DB_SCHEMA
go run ./cmd/server    # atau: make run
```

Prod: env dari systemd/podman `EnvironmentFile` (mode 600), bukan `.env`.

## Test

```bash
make check                 # vet + fmt + unit test
# integration test (butuh tunnel ke Postgres VPS):
MAJADU_TEST_DATABASE_URL="postgres://majadu_app:...@localhost:15432/bm_dev" go test ./internal/store/
```

## DB role & schema

Akses DB memakai role khusus **`majadu_app`** (bukan superuser):
- kredensial disimpan di VPS saja (file env mode 600, TIDAK pernah di repo ini)

**Write-path session (publish/delete/unlock) dijalankan Go langsung ke tabel**
dalam satu transaksi (port `publish_session`/`delete_session` era SQL) — butuh
privilege tabel, bukan lagi EXECUTE fungsi. GRANT disediakan di file migration
`000003` (aplikasikan sekali bersama drop fungsi write-path lama; anon tetap
tanpa akses apa pun). Migration ada di VPS: `/srv/qouver/majadu/migrations/`.

**Read-path session/player juga Go** (rebuild snapshot, list sessions/players,
player stats — diverifikasi identik via `TestIntegrationReadPathParity`):
GRANT SELECT tabel tournament di `000004` (stats membaca tabel tournament
langsung).

**Tournament juga sudah Go** (write + read + register pemain — diverifikasi via
`TestIntegrationTournamentParity`): GRANT DML di `000005`.

**Sisa fungsi SQL**: hanya `normalize_player_name` (dipakai CHECK constraint
`player_aliases`) + utilitas `delete_player` / trigger `set_updated_at`. Semua
logika bisnis (session, player, tournament) sudah 100% di Go.

**Schema via `MAJADU_DB_SCHEMA` (env), BUKAN hardcode di SQL.** Store memakai
kueri tanpa prefix schema; `search_path` diarahkan per-koneksi. Ini penting
untuk alur branch: `dev` → `MAJADU_DB_SCHEMA=bm_dev`, `main` → `bm` — merge
dev→main tidak membawa schema dev ke prod.

## Deploy

**Arsitektur:** image di-build GitHub Actions → push `ghcr.io/nferdazel/majadu-api:{dev,main}` →
VPS (rootless podman + systemd user/quadlet) pull & run → Caddy TLS.

```
Vercel (frontend)                          VPS api.qouver.com (Caddy)
main      → https://api.qouver.com/majadu      → 127.0.0.1:8080 (prod, bm)
dev       → https://api.qouver.com/majadu-dev  → 127.0.0.1:8081 (dev, bm_dev)
```

**Artefak di `deploy/`:**
- `majadu-api-dev.container` / `majadu-api.container` — quadlet systemd units
- `env/*.env.example` — template env (secret diisi hanya di VPS, chmod 600)
- `Caddyfile.api.qouver.com` — snippet Caddy (strip prefix `/majadu[-dev]`)

**Langkah (sekali):**
1. DNS: `api.qouver.com` → A → VPS IP (Cloudflare)
2. Apply Caddy snippet → `systemctl reload caddy`
3. VPS: buat `~/.config/containers/systemd/` + env file (`/srv/qouver/majadu/env/majadu-{dev,prod}.env`, chmod 600 — template di `deploy/env/*.env.example`)
4. `./scripts/deploy.sh setup dev`

**Update:**
- Push ke GitHub → CI build & push image → `./scripts/deploy.sh dev` (pull + restart)
- Atau otomatis: `podman auto-update` (quadlet `AutoUpdate=registry`)

**Catatan:** image ghcr.io public (tanpa auth untuk pull). Secret hanya di env file VPS — tidak pernah di repo/image.

## Branch plan

- `dev` — aktif untuk development (skema `bm_dev`)
- `main` — prod (skema `bm`), dibuat saat migrasi prod

## License

MIT — see [LICENSE](LICENSE).
