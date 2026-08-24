# Grand Plan Revamp — Clean Break dari Snapshot Monolith

> **Status:** DRAFT — 2026-08-24  
> **Author:** Muse Spark (assessment FE+BE+DB VPS)  
> **Keputusan:** Snapshot (`PUT /sessions/{id}` full `CloudSnapshot`) dihilangkan total — clean break. Semua write pindah ke granular REST + row-level OCC. Snapshot tetap sebagai *read projection* saja (GET), bukan kontrak write.
> **Prinsip:** Ideal + best practice, tanpa kompromi solo-dev. Mengejar correctness, concurrency, dan scalability untuk 60p + multi-admin live.

---

## 0. TL;DR

| Sebelum | Sesudah (Ideal) |
|---|---|
| `PUT /sessions/{id}` kirim 60 players + 36 games (15KB) tiap centang 1 checkbox | `PATCH /sessions/{id}/games/0-0/score` kirim `{a:21,b:15}` (80B) + `If-Match` per game |
| `sessions.version` global + `advisory_lock("publish_session:"+id)` → 2 admin beda game = `409` false contention | `scheduled_games.version` per game + `FOR UPDATE OF scheduled_games` row-level → 2 admin beda game = paralel, no contention |
| Validasi `ValidateSnapshot` full scan tiap write + `DELETE+INSERT` semua child (`syncSessionTables`) | Validasi field-level (`ValidateScore`) + `UPDATE` 1 row |
| SSE broadcast full snapshot 15KB, `map[chan]` in-memory hilang saat restart | Outbox `pg_notify` + SSE `patch` delta (80B) + checkpoint snapshot tiap 30s, durable |
| Idempotency in-memory 24h (`handler/session.go:18`) | Table `idempotency_keys` persistent + TTL, survive restart |

**Clean break =** `PUT /sessions/{id}` dengan `CloudSnapshot` dihapus dari kontrak write. Frontend `GeneratePage` (setup) tetap butuh 1 call create, tapi live ops tidak pernah kirim snapshot lagi.

---

## 1. Re-Assessment Menyeluruh (FE + BE + DB VPS)

### 1.1 Frontend (`badminton-match` — React 19 + Vite + TS + Zustand + TanStack Query)

**Entry & shell:** `src/main.tsx` → `src/App.tsx` routes + PWA. `HomeLayout` 6 cards, `SessionLayout` wizard `setup → players → constraints → generate`.

**State layer (saat ini):**
- `src/types/index.ts` — `PlayerId/GameKey` branded, `CloudSnapshot` (version?, session, players[60], schedule[36], playedGames, gameScores, absentPlayers)
- `src/store/index.ts` — 5 slices (`sessionSlice`, `playersSlice`, `scheduleSlice`, `fixMatchesSlice`, `uiSlice`) persisted `badminton-store v14` (wipe-on-bump). `sessionSlice.setPlayerCount` sudah clamp `4..60`, `playersSlice.addPlayers` guard cap — benar untuk setup, tapi live state masih duplikat dari server.
- `src/utils/sessionSnapshot.ts` — helpers `setScoreInSnapshot`, `swapPlayersInSnapshot`, dll. Semua pure tapi dipakai untuk membangun full snapshot tiap mutation.
- `src/queries/` — `endpoints.ts` `request()` retry method-aware (`retry.ts` hanya `429` untuk mutation), `sessions.ts` 7 hooks semua via `useOptimisticSessionMutation` factory (`useOptimisticMutation.ts`). `usePublishSession` masih fallback `snap.version ?? current?.version` (dual contract). `SharedSessionPage` polling? sudah ganti `useSessionRealtime` SSE `EventSource` `/watch`.
- `src/generator/index.ts` — 5-phase engine (pinned → merge pairable → spread → flexible → greedy fill). Pure, zero store deps. Sudah handle 60p (`totalGames 36 → avg 2.4`) tapi `GROUPING_TRIES=40`, `FILL_CANDIDATES=8` masih OK. `quality.ts` `backToBackFloor = 4*(Ci+Cj)-P` untuk 60p = 0 (no forced overlap).
- `src/utils/time.ts` — `computeSlotAllocation`, `todayWIB()` (sinkron dengan BE `Asia/Jakarta` auto-lock), `formatMergedCourtTimes`.

**Kekurangan FE ideal view:**
- God hook `useOptimisticSessionMutation` → semua live mutation bawa full snapshot. `onError` merge `fresh.version` + `optimistic` body (`useOptimisticMutation.ts:86`) = last-write-wins field lain.
- `queryKey: ['session', id]` tunggal → invalidate 1 game = refetch 60 players. Tidak normalized. `ShareButton` `lz-string` compress snapshot ke URL `?s=` → 60p ~6KB, dekat limit URL 2048.
- `SummaryModal` + `ScheduleGrid` re-render 36 rows tiap SSE full snapshot.

### 1.2 Backend (`majadu-api` — Go 1.26 + pgx + stdlib net/http)

**Topologi:** `cmd/server/main.go` → `config.Load()` (fail-fast `DATABASE_URL`, `MAJADU_DB_SCHEMA`), `db.NewPool` (`MaxConns 10`, `search_path = schema, public`, `slowQueryTracer >200ms`), `store.NewSessionStore(pool, schema)` single instance (watchers SSE per-instance), `registerRoutes` + middleware `Recover → RequestID → Logging → CORS → RateLimit (120/min)` → `http.Server` `Read 10s Write 30s`.

**Write path (sekarang, mau dibunuh):** `handler/session.go:282 Put` → `versionRequired` (If-Match atau body) → `EnsurePlayersRegistered` → `Store.Save` (`store/session.go:438`) → `pg_try_advisory_xact_lock("publish_session")` → `SELECT ... FOR UPDATE NOWAIT sessions` → `ValidateSnapshot` → `resolvePlayerAliases` → `firstSetPlayerTier` (sticky D..A+) → `syncSessionTables` (DELETE+INSERT `session_players/courts/fix_matches/scheduled_games`) → `countScoredGames == len(schedule)` auto-lock → `Broadcast`. Idempotency in-memory `map[session:key] → snap` 24h (`handler/session.go:307`).

**Read path:** `Store.Load` (`RepeatableRead` `SET TRANSACTION READ ONLY`) rebuild `CloudSnapshot` dari `sessions + session_courts + session_players + fix_matches + scheduled_games + scheduled_game_players` — identik dengan kontrak lama.

**Rating:** `internal/domain/rating.go` Glicko-1-lite pure, `store/rating*` ingest/revert/rebuild idempotent, `rating_sources` fingerprint. Auto-lock ticker `30m` + auto-ingest di `main.go:88`.

**Kekurangan BE ideal view:**
- Session-level lock → false contention. `syncSessionTables` O(N) write amplification. `ValidateSnapshot` O(N) tiap score. `idempotencyStore` hilang saat restart → double-apply risk. `Subscribe/Broadcast` `map[chan]` loss on restart + buffer 4 drop.

### 1.3 DB VPS (`qouver-postgres:5432`, host `198.51.100.10`, schema `bm` prod / `bm_dev` dev)

**Migrasi:** `/srv/qouver/majadu/migrations/000001–000011` (tidak di repo public). Baseline: `players` (8-tier CHECK D..A+, gender M/F), `player_aliases` (UNIQUE alias_name), `sessions` (id UUID, share_code `s+10alnum`, version INT, status draft/locked, session_date, session_start, slot_minutes), `session_players` (player_id FK, gender, tier, is_absent, absent_order), `session_courts` (court_index, name, start/end), `fix_matches` (legacy_ref), `scheduled_games` (internal_id, legacy_order, slot, court, status, is_played, played_order, score_a/b), `scheduled_game_players` (team A/B pos 0/1), `tournaments` + classic/team tables, `rating_*` (config, players, events, deltas, sources, season_player_snapshots). `search_path` per `MAJADU_DB_SCHEMA` (dev `bm_dev`, prod `bm`) — kueri tanpa prefix, merge branch aman.

**Infra:** `db.NewPool` 10 conns, `pgxpool` `MinConns 1`, quadlet `majadu-api.container` (`:8080 bm`) + `majadu-api-dev.container` (`:8081 bm_dev`) `AutoUpdate=registry`, Caddy `api.qouver.com` strip `/majadu[-dev]`, logs `/srv/qouver/majadu/logs/{main,dev}/app-YYYY-MM-DD.log` retensi 7 hari, `config.RateLimitPerMin 120`.

**Kekurangan DB ideal view:**
- `scheduled_games` tidak punya `version` per row → OCC impossible granular. Tidak ada `outbox_events`, `idempotency_keys` persistent, `updated_at` trigger hanya `set_updated_at` utilitas. Tidak ada `pg_notify` channel untuk multi-instance SSE.

---

## 2. Kenapa Snapshot Harus Dihilangkan (Clean Break)

Bukan "diperbaiki", tapi **dihapus dari write path**. Alasan best practice:

1.  **Aggregate terlalu besar** — 1 aggregate 60 players × 36 games = 96 child rows. Single aggregate OCC tidak scale. DDD bilang split aggregate root.
2.  **Contoh bug nyata minggu lalu:** 2 admin score beda game → `409` padahal tidak overlap. Ini bukan edge, ini arsitektur salah.
3.  **Snapshot = hidden coupling** — FE harus tahu `fixMatches`, `courtTimes` untuk kirim score. Field tidak terkait ikut terkirim, risk overwrite `firstSetPlayerTier` sticky.
4.  **Best practice REST:** Resource harus addressable. `/sessions/{id}` adalah collection, `/games/{key}` adalah resource. Score adalah state game, bukan state session.

**Keputusan:** `PUT /sessions/{id}` (CloudSnapshot) **deprecated + dihapus** setelah `v2` granular live 1 rilis. Sisa 1 endpoint `POST /sessions` untuk create (setup) + `GET /sessions/{id}` untuk bootstrap read (projection). Semua live ops wajib granular.

---

## 3. Target Architecture Ideal (Granular v2)

### 3.1 High-Level Shape

```
FE (React Query normalized) ──PATCH granular──▶ BE (Go) ──UPDATE 1 row──▶ Postgres
       ▲                                 │                    │
       └────── SSE patch delta ◀── outbox + pg_notify ◀───────┘
```

- **Command side:** `PATCH /sessions/{id}/games/{key}/score` etc → row-level `FOR UPDATE` → `outbox_events` → commit.
- **Query side:** `GET /sessions/{id}` tetap full projection (untuk bootstrap), `GET /sessions/{id}/games` + `GET /sessions/{id}/players` untuk normalized cache.

### 3.2 DB Schema v2 (Migration 000012)

```sql
-- per-entity version + audit
ALTER TABLE scheduled_games ADD COLUMN version BIGINT NOT NULL DEFAULT 1;
ALTER TABLE scheduled_games ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
CREATE TRIGGER trg_scheduled_games_updated_at BEFORE UPDATE ON scheduled_games
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- idempotency persistent (survive restart)
CREATE TABLE idempotency_keys (
  session_id UUID NOT NULL,
  key TEXT NOT NULL,
  response JSONB NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (session_id, key)
);
CREATE INDEX ON idempotency_keys(expires_at);

-- outbox untuk SSE durable
CREATE TABLE outbox_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  aggregate TEXT NOT NULL, -- 'game' | 'player' | 'session'
  aggregate_id TEXT NOT NULL, -- '0-0' | player_ref
  event_type TEXT NOT NULL, -- 'score_set' | 'played_toggled' | 'absent_set' | 'swap'
  payload JSONB NOT NULL,
  version BIGINT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX ON outbox_events(session_id, id);
-- notify channel
-- BE: SELECT pg_notify('majadu_events', json_build_object('session_id', $1, 'event_id', $2)::text)
```

### 3.3 API Contract v2 (OpenAPI)

```yaml
# BOOTSTRAP READ (tetap)
GET /sessions/{id} -> CloudSnapshot (projection, ETag: W/"v11")
POST /sessions -> {id, snapshot} (create, dari GeneratePage)

# GRANULAR LIVE (baru, pengganti PUT snapshot)
PATCH /sessions/{id}/games/{key}          # score | played
  body: {scoreA?: int, scoreB?: int, isPlayed?: bool}
  headers: If-Match: W/"v3" (game version), Idempotency-Key: uuid
PATCH /sessions/{id}/players/absent
  body: {playerIds: string[]}
  headers: If-Match: W/"v11" (session version)
POST /sessions/{id}/games/swap
  body: {type: "player"|"team"|"slot", a:{slot,court,team,pos}, b:{...}}
  headers: If-Match: W/"v11", Idempotency-Key
GET /sessions/{id}/events?since=123 -> {events: [{id, event_type, payload, version}], nextSince}
GET /sessions/{id}/watch -> SSE: event: patch {op, path, value, version} | event: snapshot (checkpoint 30s)
```

`PUT /sessions/{id}` dihapus di docs, BE kembalikan `410 Gone` setelah 1 rilis deprecation.

### 3.4 Backend Design (Go)

- **Handler:** `SessionHandler.SetScore`, `TogglePlayed`, `SetAbsent`, `Swap` — masing-masing `versionRequired(r)` per game/session, `checkIdempotency(session_id, key)` persistent, `store.SetScore(ctx, sessionID, slot, court, a, b, expectedVersion)`.
- **Store:** Per method `tx.Begin()`, `SELECT version FROM scheduled_games WHERE session_id=$1 AND slot=$2 AND court=$3 FOR UPDATE NOWAIT`, bandingkan `expected`, `UPDATE ... SET score_a=$1, score_b=$2, is_played=true, version=version+1, updated_at=now()`, `INSERT INTO outbox_events`, `INSERT INTO idempotency_keys ON CONFLICT DO NOTHING`, `COMMIT`, lalu `pg_notify`.
- **Watch:** Ganti `Subscribe(map[chan])` in-memory jadi `LISTEN majadu_events` per instance + poll `outbox_events WHERE id > $since`. SSE kirim `data: {"event_type":"score_set","key":"0-0","a":21,"b":15,"version":4}` — FE patch 1 game.

### 3.5 Frontend Design (React + TS + TanStack)

- **Query keys normalized:**
  ```ts
  ['session', id] // metadata
  ['session', id, 'games'] // list
  ['session', id, 'games', '0-0'] // per game
  ['session', id, 'players']
  ```
- **Mutations granular:**
  ```ts
  useSetScore(sessionId, gameKey) {
    const qc = useQueryClient()
    return useMutation({
      mutationFn: ({a,b, expectedVersion}) => request('PATCH', `/sessions/${id}/games/${key}`, {scoreA:a,scoreB:b}, {IfMatch: `W/"v${expectedVersion}"`, IdempotencyKey}),
      onMutate: optimistic set per gameKey,
      onError: rollback per gameKey + refetch per gameKey
    })
  }
  ```
- **SSE delta:** `useSessionRealtime` parse `event: patch` → `qc.setQueryData(['session', id, 'games', key], applyPatch)`. `event: snapshot` → `qc.setQueryData(['session', id], snapshot)`.
- **GeneratePage:** Tetap `POST /sessions` dengan `CloudSnapshot` awal (1x). Live tidak pernah `PUT`.

### 3.6 Clean Break Migration

**Fase 0 — DB (1 hari):** Migration `000012` add columns + tables. Deploy BE tanpa pakai (backward compat).

**Fase 1 — BE granular (2 hari):** Implement 4 handlers + store methods + `LISTEN/NOTIFY` + SSE patch. `PUT` snapshot masih hidup tapi log `WARN deprecated`.

**Fase 2 — FE granular (3 hari):** Branch `feat/granular-live` ganti `queries/sessions.ts` 7 hooks ke granular. Hapus `useOptimisticSessionMutation` untuk live. `SharedSessionPage` + `ScheduleGrid` pakai per-game keys.

**Fase 3 — Dual run & parity (2 hari):** `TestConcurrentSetScoreDifferentGames_NoContention` (2 goroutine PATCH beda key → both 200), `TestConcurrentSameGame_Conflict` (expected 409), `TestIdempotencyReplay` (same Idempotency-Key → same response, no double bump). SSE patch vs full snapshot parity.

**Fase 4 — Deprecate snapshot (1 hari):** FE tidak kirim `PUT` lagi. BE `PUT /sessions/{id}` → `410 Gone` + docs `api/openapi.yaml` hapus `SessionDraft maxItems`.

**Fase 5 — Hardening:** Rate limit per game, metrics `game_version_conflicts_total`, `outbox_lag_seconds`, log `slowQuery >200ms` sudah ada (`db/db.go`).

---

## 4. Risk & Mitigasi

| Risk | Mitigasi |
|---|---|
| Rollback butuh snapshot | Keep `GET /sessions/{id}` projection + `GET /events?since` replay. Snapshot bisa rebuild kapan saja dari `scheduled_games`. |
| Client lama masih PUT | BE `410` dengan pesan `use PATCH /games/{key}` + FE versi lama paksa update via PWA `UpdateBanner`. |
| Deadlock swap 2 games | Lock rows `ORDER BY (slot,court)` + `advisory_xact_lock("swap:"+sessionID)` serialize swap. |
| Outbox bengkak | Retention 7 hari, cron `DELETE WHERE created_at < now()-7d`. |

---

## 5. Checklist Rollout

- [x] **Fase 0 — DB migration `000012`** (docs/migration-000012-granular-live.md): `scheduled_games.version/updated_at` + trigger, `idempotency_keys`, `outbox_events`. Additive `IF NOT EXISTS`, backward-compat. **Belum di-apply di VPS** — jalankan di `bm_dev` lalu `bm`.
- [x] **Fase 1 — BE granular** (`majadu-api`): `PATCH /sessions/{id}/games/{gameKey}` (score/played, row-level `FOR UPDATE NOWAIT` + OCC per game), `PATCH /sessions/{id}/absent` (session-level, tanpa full rewrite), `GET .../games/{gameKey}` (version untuk OCC). Idempotency persistent. PUT snapshot tetap jalan.
- [x] **Fase 2 — FE granular** (`badminton-match`): `useSetScore`/`useTogglePlayed`/`useSetAbsent` → PATCH granular (fetch game version → PATCH, retry 1x on conflict). API hook dipertahankan (zero UI change). Fix edge case toggle-intent.
- [x] **Fase 3 — Tests**: unit strict `splitGameKey` (tolak malformed/negatif/spasi — bug lama), `isUndefinedTable`, metrics; integration DB-guarded: different-games no contention, same-game conflict, idempotency no double-bump, played toggle clears score, absent granular.
- [x] **Fase 4 — Deprecate PUT**: header `X-Snapshot-Deprecated` + Warn log; openapi mark `put` deprecated + kontrak granular. Hard `410` ditunda (PUT masih dipakai GeneratePage setup + swap hooks).
- [x] **Fase 5 — Hardening**: auto-lock saat skor terakhir via granular (fix regression rating ingest), `GET /sessions/{id}/events` (outbox replay), `GET /metrics` (counter in-memory), `isUndefinedTable` via `pgconn` (robust).

**Belum dikerjakan (next session):**
- [ ] Apply migration `000012` di VPS (`bm_dev` → `bm`) — wajib sebelum granular diaktifkan penuh di prod.
- [ ] Swap granular (`POST /sessions/{id}/games/swap`) — butuh review skema `scheduled_game_players` di VPS (constraint team/position) sebelum DML swap.
- [ ] SSE durable via `pg_notify`/outbox poll di `Watch` (sekarang masih in-memory `map[chan]`).
- [ ] Hard `410` PUT setelah semua live op granular + FE tidak lagi kirim PUT live.
- [ ] Deploy `dev` → smoke 60p 2 HP score beda game → expect 200 both.
- [ ] Merge `dev` → `main` fast-forward, `rev-list 0 0`.

---

## 6. Keputusan Terbuka

- `PATCH` body pakai JSON Patch RFC 6902 `[{op:"replace",path:"/scoreA",value:21}]` atau flat `{scoreA,scoreB}`? Rekomendasi flat untuk simplicity.
- `version` per game pakai `BIGINT` atau `ETag` opaque? Rekomendasi `BIGINT` + `W/"v{n}"` header (sudah ada `strconv.Itoa` di `writeSession`).
- Butuh `GET /sessions/{id}/games/{key}` single? Opsional, `GET /sessions/{id}` + `events` cukup.

---

*Dokumen ini adalah grand plan clean break. Eksekusi dimulai dari DB migration 000012.*
