# Current Status

Last updated: 2026-08-22 (migrasi prod, checklist/absent fix, auto-deploy — semua DEPLOYED)

This is the fastest handover file. Start here, lalu baca dokumen terkait di bawah.

## REPO & BRANCH

```
badminton-match (React 19 PWA) ──REST──▶ majadu-api (Go 1.26, net/http+pgx) ──▶ Postgres VPS
  dev  (aktif) · DEPLOYED Vercel        dev  (aktif) · DEPLOYED podman   DB bm_dev (data live)
  main = dev (synced)                   main = dev (synced)                DB bm (prod, data live)
```

- Frontend `main` → Vercel (auto-deploy dari push)
- Backend `main` → GitHub Actions → SSH ke VPS → podman pull + restart
- Auto-deploy: push ke main/dev = deploy otomatis
- API dev: `https://api.qouver.com/majadu-dev` (port 8081)
- API prod: `https://api.qouver.com/majadu` (port 8080)

## ✅ Yang SELESAI (2026-08-22)

### 1. PROD MIGRATION (Supabase → VPS)

| Step | Status |
|------|--------|
| Clean bm_dev | ✅ |
| Apply migrated.sql (125 players, 27 sessions) | ✅ |
| 93 tier overrides | ✅ |
| Cleanup Free players (player_id = NULL) | ✅ |
| Set gender + registered_at | ✅ |
| Tournament import (1 classic, 16 pairs, 32 matches) | ✅ |
| Rating config (22 rows dari bm) | ✅ |
| Rating ingest (18 sessions, 384 events, 103 players) | ✅ |
| Migrate bm_dev → bm (schema + data 1:1) | ✅ |

### 2. CHECKLIST / ABSENT FIX

| Fix | Detail |
|-----|--------|
| Checklist persist | mutationFn double-toggle bug fixed |
| Mark absent no void | Games tetap jalan, absent player tidak dapat rating delta |
| Checklist guard removed | Checkbox tetap bisa dicentang untuk game dengan absent player |
| Played count | Semua checked games dihitung (termasuk yang ada absent) |
| Version mismatch retry | Silent retry 1x sebelum error |

### 3. AUTO-DEPLOY

- GitHub Actions: test → build → push ke GHCR → SSH ke VPS → podman pull + restart
- Push ke main/dev = deploy otomatis
- Log separation: main di `/srv/qouver/majadu/logs/main/`, dev di `/srv/qouver/majadu/logs/dev/`

### 4. TEAM TOURNAMENT IMPROVEMENTS

- Manual team assignment di wizard (Step 2)
- Editable team names di standings
- Team member display di standings
- Court assignment per match (3 courts)
- Champion banner di final tab
- Final tab: nama tim di samping "FINAL"

### 5. OTHER FIXES

- 19 bug fixes (stale closure, race conditions, etc.)
- Font: IBM Plex Mono → IBM Plex Sans (1 font)
- Pagination: ratings leaderboard, recent matches, session list
- Peak rating removed from leaderboard list

## Infrastruktur

- VPS `sachiel@43.133.148.191`
- Containers: `majadu-api` (main:8080), `majadu-api-dev` (dev:8081), `qouver-postgres` (5432)
- Quadlet configs: `~/.config/containers/systemd/majadu-api*.container`
- Auto-deploy: GitHub Actions → SSH → podman pull + restart
- Log: `/srv/qouver/majadu/logs/{main,dev}/app-YYYY-MM-DD.log`

## Database

| Database | Tables | Status |
|----------|--------|--------|
| `bm_dev` | 24 | 125 players, 27 sessions, 103 rated, 1 tournament |
| `bm` (prod) | 24 | 125 players, 27 sessions, 103 rated, 1 tournament |

Rating config: 22 rows (season_start 2026-05-23, 8-tier ClassBands, session_tier_init)

## Cara Lanjut

1. Visual pass browser (user)
2. Branch protection testing
3. Team tournament share/export
4. E2E testing
5. Ganti password `qouver`
