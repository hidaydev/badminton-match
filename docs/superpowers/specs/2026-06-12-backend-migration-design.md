# Backend Migration: Apps Script → Vercel Functions + Neon Postgres

**Date:** 2026-06-12
**Status:** Approved for implementation

## Problem

The current backend is Google Apps Script writing to Google Sheets. It suffers from:
- Cold starts: 3–5s per request after idle
- Sheets I/O latency on every read/write
- No concurrent write safety
- Full JSON blob rewritten on every mutation (~50KB per save)

## Goal

Replace Apps Script with Vercel Serverless Functions + Neon Postgres (free tier). Keep the same `CloudSnapshot` response shape so frontend query changes are minimal.

## Stack

| Layer | Choice |
|---|---|
| Functions | Vercel Serverless (flat `/api/` files) |
| Database | Neon Postgres (via `@neondatabase/serverless`) |
| Connection pooling | Neon pgBouncer (must enable to avoid connection exhaustion) |
| Auth | `Authorization: Bearer <token>` — same as current |
| Migration | One-time Node.js script reading from Apps Script, writing to Postgres |

## Database Schema

```sql
CREATE TABLE sessions (
  id              TEXT PRIMARY KEY,
  title           TEXT,
  date            DATE,
  session_start   TEXT,
  slot_minutes    INTEGER,
  slots_per_court INTEGER[],
  court_names     TEXT[],
  court_times     JSONB,
  tier_count      INTEGER,
  created_at      TIMESTAMPTZ,
  updated_at      TIMESTAMPTZ
);

CREATE TABLE session_players (
  id          TEXT PRIMARY KEY,       -- session-scoped player id e.g. "s095dk0"
  session_id  TEXT REFERENCES sessions(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  gender      TEXT,
  tier        INTEGER
);

CREATE TABLE games (
  id          TEXT PRIMARY KEY,       -- "{session_id}-{slot}-{court}"
  session_id  TEXT REFERENCES sessions(id) ON DELETE CASCADE,
  slot        INTEGER NOT NULL,
  court       INTEGER NOT NULL,
  team_a_p1   TEXT REFERENCES session_players(id),
  team_a_p2   TEXT REFERENCES session_players(id),
  team_b_p1   TEXT REFERENCES session_players(id),
  team_b_p2   TEXT REFERENCES session_players(id),
  played      BOOLEAN DEFAULT false,
  score_a     INTEGER,
  score_b     INTEGER
);

CREATE TABLE fix_matches (
  id          TEXT PRIMARY KEY,
  session_id  TEXT REFERENCES sessions(id) ON DELETE CASCADE,
  slots       TEXT[]                  -- array of 4 player ids
);

CREATE TABLE absent_players (
  session_id  TEXT REFERENCES sessions(id) ON DELETE CASCADE,
  player_id   TEXT REFERENCES session_players(id) ON DELETE CASCADE,
  PRIMARY KEY (session_id, player_id)
);

CREATE TABLE tournaments (
  id          TEXT PRIMARY KEY,
  data        JSONB NOT NULL,
  created_at  TIMESTAMPTZ,
  updated_at  TIMESTAMPTZ
);

-- Indexes for common queries
CREATE INDEX idx_games_session ON games(session_id);
CREATE INDEX idx_session_players_session ON session_players(session_id);
CREATE INDEX idx_session_players_name ON session_players(name);
CREATE INDEX idx_sessions_date ON sessions(date DESC);
```

## API Endpoints (Flat Vercel Functions)

All endpoints require `Authorization: Bearer <token>` header.
All responses: `{ ok: true, data: ... }` or `{ ok: false, error: "..." }`

### Sessions

| Method | File | URL | Description |
|---|---|---|---|
| GET | `api/sessions.ts` | `/api/sessions` | List sessions (metadata + player count) |
| POST | `api/sessions.ts` | `/api/sessions` | Create full session (schedule + players) |
| GET | `api/session.ts` | `/api/session?id=xxx` | Get full session as CloudSnapshot |

### Game mutations

| Method | File | URL | Description |
|---|---|---|---|
| PATCH | `api/game-played.ts` | `/api/game-played` | Toggle played `{ sessionId, gameId }` |
| PATCH | `api/game-score.ts` | `/api/game-score` | Set score `{ sessionId, gameId, a, b }` |
| POST | `api/swap-players.ts` | `/api/swap-players` | Swap two players `{ sessionId, t1, t2 }` |
| POST | `api/swap-slots.ts` | `/api/swap-slots` | Swap two slots `{ sessionId, g1, g2 }` |
| PUT | `api/absent.ts` | `/api/absent` | Set absent list `{ sessionId, playerIds[] }` |
| PATCH | `api/replace-player.ts` | `/api/replace-player` | Rename player `{ sessionId, playerId, newName }` |

### Players

| Method | File | URL | Description |
|---|---|---|---|
| GET | `api/players.ts` | `/api/players` | All unique player names + session count |
| GET | `api/player-stats.ts` | `/api/player-stats?name=xxx` | Career stats for one player |

### Tournament

| Method | File | URL | Description |
|---|---|---|---|
| GET | `api/tournament.ts` | `/api/tournament?id=xxx` | Get tournament snapshot |
| PUT | `api/tournament.ts` | `/api/tournament` | Save tournament snapshot |

## CloudSnapshot Assembly

`GET /api/session?id=xxx` assembles the response from 4 tables:

```ts
{
  session: { ...sessions row },
  players: [ ...session_players rows ],
  fixMatches: [ ...fix_matches rows ],
  schedule: games rows mapped to { slot, court, teamA, teamB },
  playedGames: games where played=true → ["slot-court", ...],
  gameScores: games with scores → { "slot-court": { a, b } },
  absentPlayers: [ ...absent_players.player_id ],
}
```

## Player Stats Query

```sql
-- All games a player participated in, across all sessions
SELECT
  g.*,
  s.date,
  sp_target.name AS player_name
FROM games g
JOIN session_players sp_target
  ON sp_target.id IN (g.team_a_p1, g.team_a_p2, g.team_b_p1, g.team_b_p2)
JOIN sessions s ON s.id = g.session_id
WHERE sp_target.name ILIKE $1
  AND g.played = true
```

Partners and opponents resolved in application layer from the four player ID columns.

## Frontend Changes

Minimal — only `src/queries/endpoints.ts` needs updating:

1. Replace `VITE_APPS_SCRIPT_URL` env var with `VITE_API_URL` + `VITE_API_TOKEN`
2. Change each fetch to hit the new flat endpoints with `Authorization` header
3. POST body shape changes slightly (add `sessionId` to mutation payloads)

The `CloudSnapshot` type is unchanged. All hooks (`useGetSession`, `useTogglePlayed`, etc.) stay the same.

## Migration Script

One-time script (`scripts/migrate-to-postgres.mjs`):

1. Fetch all sessions from Apps Script (`?action=list` then `?id=xxx` for each)
2. Parse each JSON blob into normalized rows
3. Insert into Postgres in order: sessions → session_players → games → fix_matches → absent_players
4. Fetch and insert tournament data

## Environment Variables

```env
# Frontend (.env)
VITE_API_URL=https://<project>.vercel.app
VITE_API_TOKEN=<secret>

# Vercel dashboard (Functions env)
DATABASE_URL=<neon-pooled-connection-string>
API_TOKEN=<secret>
```

## Vercel Limits (Hobby Free Tier)

| Limit | Value | Expected usage |
|---|---|---|
| Function timeout | 10s | ~50–150ms per request |
| Invocations | 100K/month | Well under for a club |
| Neon storage | 0.5 GB | ~1 MB for all sessions |
| Neon cold start | ~500ms after idle | Acceptable |

Neon pgBouncer connection string (pooled) must be used — not the direct connection string — to avoid connection limit exhaustion from serverless cold starts.
