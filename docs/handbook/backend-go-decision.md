# Keputusan Arsitektur: Backend Go (menggantikan PostgREST RPC)

> **Status:** Accepted — 2026-08-11
> **Pemutus:** sachiel (diskusi sesi 2026-08-11)
> **Tujuan dokumen:** pegangan antar sesi — konteks, keputusan, dan langkah tanpa kehilangan arah.

---

## 1. Konteks

App Majadu (React 19 PWA) saat ini memakai **PostgREST + RPC functions** sebagai backend:
- prod: Supabase (schema `bm`, RPC `bm.*`)
- dev/staging: VPS `mjd-api.qouver.com` (PostgREST + GoTrue + Postgres 18, schema `bm_dev`)

Model ini bekerja, tapi:
- Logika backend hidup di fungsi SQL (SECURITY DEFINER) — canggung untuk auth, logging, rate limiting, testing.
- Akses anon dibatasi lewat grants + PUBLIC-revoke (sudah di-hardening, lihat baseline migrasi V2).
- RLS "bener-bener" tidak masuk akal tanpa login, dan login via GoTrue + wiring RLS berat.

**Keputusan:** bangun **backend Go** yang menjadi satu-satunya backend — dev/staging dulu
sampai stabil, lalu **prod ikut migrasi** (Supabase ditinggalkan).

## 2. Struktur repo & mapping branch

```
badminton-match (frontend)         majadu-api (backend Go)
├── main      → prod               ├── main   → prod
└── dev       → dev                └── dev    → dev
```

- Branch frontend `dev` memakai backend Go branch `dev`.
- Branch frontend `main` memakai backend Go branch `main` (setelah migrasi prod).
- Nama branch frontend `dev` (dulu `ui-revamp`, di-rename 2026-08-15) — konsisten dengan backend.

## 3. Topologi target

```
DEV/STAGING:  frontend (Vercel preview) ──▶ Go backend (VPS, branch dev)
                                                 └──▶ Postgres VPS (bm_dev)
PROD:         frontend (Vercel prod)    ──▶ Go backend (VPS, branch main)
                                                 └──▶ Postgres VPS (bm — migrasi data dari Supabase)
Supabase/PostgREST: dipensiunkan setelah prod stabil di Go backend.
```

Mekanisme `__BACKEND_PROFILE__` (vite.config, mapping `VERCEL_GIT_COMMIT_REF`)
berevolusi dari "schema profile" menjadi **branch → base URL Go backend**.

## 4. Keputusan detail

| Topik | Keputusan | Catatan |
|---|---|---|
| **Data model** | Schema `bm`/`bm_dev` tetap source of truth | Baseline migrasi V2 (2026-08-11) sudah up-to-date dengan state VPS |
| **Kontrak API** | ⏳ Belum diputuskan — rekomendasi: **mirror kontrak snapshot** yang ada (10 operasi, JSON sama) | App nyaris tak berubah (cukup ganti base URL di `endpoints.ts`); RESTful granular = opsi lebih bersih tapi rombak query layer |
| **Auth/Login** | ⏳ Ditunda — jika butuh, middleware JWT/session di Go | Bukan RLS; pemain di venue tetap tanpa friction |
| **RLS** | Default-deny + satu app role (Go = satu-satunya client DB) | Kerja grants/PUBLIC-revoke sekarang = safety net transisi |
| **DB akses** | Go backend langsung ke Postgres (pgx) | — |

## 5. Operasi yang harus di-reimplement di Go

Kontrak saat ini (dari `src/queries/endpoints.ts`):

- **Session:** get_session, publish_session, list_sessions, delete_session, unlock_session
- **Player:** list_players, get_player_stats (termasuk tournamentStats), register_player
- **Tournament:** get_tournament, publish_tournament
- **Invariant:** version concurrency, lock enforcement (status ≠ draft → tolak write),
  validasi snapshot, resolve player/alias, TOCTOU-safe register.

Catatan: bracket propagation turnamen masih di TS app (mengirim snapshot hasil compute).

## 6. Fase eksekusi

1. **Dokumen ini** (2026-08-11) ✅
2. **POC Go backend** — service HTTP (rekomendasi stdlib `net/http` + `pgx`, cost-conscious)
   di VPS, konek `bm_dev`, implementasi 3 operasi: get_session, publish_session, list_sessions + smoke round-trip. ✅
3. **Produksi-ready + REST** (2026-08-12) ✅ — endpoint REST penuh (sessions/players/tournaments),
   OpenAPI spec, concurrency If-Match/ETag, audit hardening, `MAJADU_DB_SCHEMA` env-driven
   (schema tidak hardcode — aman merge dev→main).
4. **Integrasi frontend `dev`** (2026-08-12) ✅ — `endpoints.ts` di-rewrite jadi REST client
   terhadap majadu-api; `__BACKEND_PROFILE__` → `__API_BASE_URL__` (branch mapping);
   bridge `PUT /sessions/{id}` & `PUT /tournaments/{id}` (full snapshot replace, kontrak lama)
   supaya alur frontend (publish snapshot + optimistic updates) tidak berubah. Verifikasi
   end-to-end: create→get→update→list→players→tournament PASS.
5. **Lengkapi operasi** — granular endpoints REST sudah ada (games/swaps/absent/lock);
   migrasi logic SQL→Go bertahap (transform sudah di Go).
6. **Stabilisasi** — smoke/writeflow E2E terhadap Go backend.
7. **Migrasi prod** — backup data `bm` (Supabase) → restore ke Postgres VPS → deploy Go
   backend main → arahkan frontend main (`__API_BASE_URL__` mapping) → pensiunkan Supabase/PostgREST.

## 7. Pertanyaan terbuka

- [ ] Nama repo backend (saran: `majadu-backend`)
- [ ] Kontrak API: mirror snapshot vs RESTful granular
- [ ] Timing auth (sebelum/bersamaan/sesudah migrasi prod)
- [ ] Subdomain Caddy untuk Go backend (mis. `api-dev.qouver.com` vs path di `mjd-api`)

## 8. Referensi

- Baseline migrasi V2: `/srv/qouver/majadu/migrations/000001_functions.sql` + `000002_schema.sql` (dulu `supabase/migrations/`, dipindah ke VPS 2026-08-15)
- Data model V2: `docs/handbook/DATA-MODEL-V2.md` (arsip dari `vps-setup/docs/`, dihapus 2026-08-15)
- Kontrak RPC app: `src/queries/endpoints.ts`
- Audit RPC & utilisasi tabel: catatan sesi 2026-08-11 (HANDOFF + DATA_MODEL_V2_TASKS.md)
