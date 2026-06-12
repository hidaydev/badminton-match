# Backend Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Google Apps Script + Sheets backend with Vercel Serverless Functions + Neon Postgres, keeping the same `CloudSnapshot` response shape so frontend changes are minimal.

**Architecture:** Flat `/api/` directory of TypeScript Vercel Functions. Each mutation hits one or two DB rows instead of rewriting a 50KB JSON blob. A one-time migration script reads all data from Apps Script and inserts it into Postgres.

**Tech Stack:** `@neondatabase/serverless` (HTTP Postgres driver), Vercel Functions (TypeScript), Neon Postgres, Node.js migration script.

---

## File Map

**New files:**
- `api/_db.ts` — shared Neon client + auth helpers
- `api/sessions.ts` — GET list, POST create
- `api/session.ts` — GET `?id=xxx` → CloudSnapshot
- `api/game-played.ts` — PATCH toggle played
- `api/game-score.ts` — PATCH set score
- `api/swap-players.ts` — POST swap two players
- `api/swap-slots.ts` — POST swap two game slots
- `api/absent.ts` — PUT set absent list
- `api/replace-player.ts` — PATCH rename player
- `api/players.ts` — GET all unique players
- `api/player-stats.ts` — GET career stats by name
- `api/tournament.ts` — GET + PUT tournament
- `scripts/schema.sql` — Postgres DDL
- `scripts/migrate-to-postgres.mjs` — one-time migration

**Modified files:**
- `package.json` — add `@neondatabase/serverless`, `@vercel/node`
- `tsconfig.node.json` — include `api/**`
- `src/queries/endpoints.ts` — replace Apps Script fetches with new endpoints
- `src/queries/sessions.ts` — update mutationFn in each hook to call targeted endpoints

---

## Task 1: Install dependencies + write schema

**Files:**
- Modify: `package.json`
- Modify: `tsconfig.node.json`
- Create: `scripts/schema.sql`

- [ ] **Step 1: Install packages**

```bash
cd /Users/hidaydev/Code/badminton-pair
npm install @neondatabase/serverless
npm install --save-dev @vercel/node
```

- [ ] **Step 2: Include `api/` in tsconfig.node.json**

Open `tsconfig.node.json`. Change the `include` array to also cover `api/**`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2023"],
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "skipLibCheck": true
  },
  "include": ["vite.config.ts", "api/**"]
}
```

- [ ] **Step 3: Write schema.sql**

Create `scripts/schema.sql`:

```sql
CREATE TABLE IF NOT EXISTS sessions (
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

CREATE TABLE IF NOT EXISTS session_players (
  id          TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  gender      TEXT,
  tier        INTEGER
);

CREATE TABLE IF NOT EXISTS games (
  id          TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
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

CREATE TABLE IF NOT EXISTS fix_matches (
  id          TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  slots       TEXT[]
);

CREATE TABLE IF NOT EXISTS absent_players (
  session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  player_id   TEXT NOT NULL REFERENCES session_players(id) ON DELETE CASCADE,
  PRIMARY KEY (session_id, player_id)
);

CREATE TABLE IF NOT EXISTS tournaments (
  id          TEXT PRIMARY KEY,
  data        JSONB NOT NULL,
  created_at  TIMESTAMPTZ,
  updated_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_games_session ON games(session_id);
CREATE INDEX IF NOT EXISTS idx_session_players_session ON session_players(session_id);
CREATE INDEX IF NOT EXISTS idx_session_players_name ON session_players(name);
CREATE INDEX IF NOT EXISTS idx_sessions_date ON sessions(date DESC);
```

- [ ] **Step 4: Create Neon project and run schema**

1. Go to https://neon.tech, sign in with GitHub
2. Create new project → name it `majadu-badminton`
3. Copy the **pooled connection string** (looks like `postgresql://user:pass@ep-xxx-pooler.region.aws.neon.tech/neondb?sslmode=require`)
4. Run the schema in Neon SQL Editor (paste contents of `scripts/schema.sql` and execute)
5. Add the connection string to Vercel project env vars as `DATABASE_URL`
6. Also add `API_TOKEN=<choose a secret string>` to Vercel env vars

- [ ] **Step 5: Add local env vars**

Create `.env.local` (gitignored) at project root:

```env
DATABASE_URL=postgresql://user:pass@ep-xxx-pooler.region.aws.neon.tech/neondb?sslmode=require
API_TOKEN=dev-secret
```

- [ ] **Step 6: Commit**

```bash
git add scripts/schema.sql package.json package-lock.json tsconfig.node.json
git commit -m "chore: add Neon Postgres deps and schema"
```

---

## Task 2: Create shared DB helper (`api/_db.ts`)

**Files:**
- Create: `api/_db.ts`

- [ ] **Step 1: Create the file**

Create `api/_db.ts`:

```ts
import { neon } from '@neondatabase/serverless'
import type { VercelRequest, VercelResponse } from '@vercel/node'

export function getDb() {
  if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL not set')
  return neon(process.env.DATABASE_URL)
}

export function checkAuth(req: VercelRequest): boolean {
  const header = req.headers['authorization'] ?? ''
  const token = header.replace('Bearer ', '').trim()
  return !!process.env.API_TOKEN && token === process.env.API_TOKEN
}

export function send(res: VercelResponse, data: unknown, status = 200) {
  return res.status(status).json({ ok: true, data })
}

export function sendError(res: VercelResponse, error: string, status = 500) {
  return res.status(status).json({ ok: false, error })
}

export function gameId(sessionId: string, slot: number, court: number) {
  return `${sessionId}-${slot}-${court}`
}

export function colFromTarget(team: 'A' | 'B', index: 0 | 1): string {
  if (team === 'A') return index === 0 ? 'team_a_p1' : 'team_a_p2'
  return index === 0 ? 'team_b_p1' : 'team_b_p2'
}
```

- [ ] **Step 2: Verify TypeScript is happy**

```bash
npx tsc --project tsconfig.node.json --noEmit
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add api/_db.ts
git commit -m "feat: add shared Neon DB helper for Vercel Functions"
```

---

## Task 3: GET + POST `/api/sessions`

**Files:**
- Create: `api/sessions.ts`

- [ ] **Step 1: Create the handler**

Create `api/sessions.ts`:

```ts
import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'
import type { CloudSnapshot, SessionMeta } from '../src/queries/types'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)

  const sql = getDb()

  if (req.method === 'GET') {
    const rows = await sql`
      SELECT s.id, s.title, s.date, s.updated_at,
        COUNT(DISTINCT sp.id)::int AS player_count,
        COUNT(DISTINCT g.id)::int AS total_games
      FROM sessions s
      LEFT JOIN session_players sp ON sp.session_id = s.id
      LEFT JOIN games g ON g.session_id = s.id
      GROUP BY s.id
      ORDER BY s.date DESC
    `
    const data: SessionMeta[] = rows.map((r) => ({
      id: r.id,
      title: r.title ?? '',
      date: r.date ? String(r.date).slice(0, 10) : '',
      playerCount: r.player_count,
      totalGames: r.total_games,
    }))
    return send(res, data)
  }

  if (req.method === 'POST') {
    const snap = req.body as { id: string; data: CloudSnapshot }
    const { id, data } = snap
    const s = data.session
    const now = new Date().toISOString()

    await sql`
      INSERT INTO sessions (id, title, date, session_start, slot_minutes, slots_per_court, court_names, court_times, tier_count, created_at, updated_at)
      VALUES (${id}, ${s.title}, ${s.date}, ${s.sessionStart}, ${s.slotMinutes},
        ${s.slotsPerCourt}, ${s.courtNames}, ${JSON.stringify(s.courtTimes)},
        ${s.tierCount ?? 4}, ${now}, ${now})
      ON CONFLICT (id) DO UPDATE SET
        title = EXCLUDED.title, date = EXCLUDED.date,
        session_start = EXCLUDED.session_start, slot_minutes = EXCLUDED.slot_minutes,
        slots_per_court = EXCLUDED.slots_per_court, court_names = EXCLUDED.court_names,
        court_times = EXCLUDED.court_times, tier_count = EXCLUDED.tier_count,
        updated_at = EXCLUDED.updated_at
    `

    for (const p of data.players) {
      await sql`
        INSERT INTO session_players (id, session_id, name, gender, tier)
        VALUES (${p.id}, ${id}, ${p.name}, ${p.gender}, ${p.tier})
        ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, gender = EXCLUDED.gender, tier = EXCLUDED.tier
      `
    }

    const playedSet = new Set(data.playedGames)
    for (const g of data.schedule) {
      const gid = `${id}-${g.slot}-${g.court}`
      const key = `${g.slot}-${g.court}`
      const score = data.gameScores?.[key]
      const played = playedSet.has(key)
      await sql`
        INSERT INTO games (id, session_id, slot, court, team_a_p1, team_a_p2, team_b_p1, team_b_p2, played, score_a, score_b)
        VALUES (${gid}, ${id}, ${g.slot}, ${g.court}, ${g.teamA[0]}, ${g.teamA[1]}, ${g.teamB[0]}, ${g.teamB[1]},
          ${played}, ${score?.a ?? null}, ${score?.b ?? null})
        ON CONFLICT (id) DO UPDATE SET
          team_a_p1 = EXCLUDED.team_a_p1, team_a_p2 = EXCLUDED.team_a_p2,
          team_b_p1 = EXCLUDED.team_b_p1, team_b_p2 = EXCLUDED.team_b_p2,
          played = EXCLUDED.played, score_a = EXCLUDED.score_a, score_b = EXCLUDED.score_b
      `
    }

    await sql`DELETE FROM fix_matches WHERE session_id = ${id}`
    for (const fm of data.fixMatches ?? []) {
      await sql`
        INSERT INTO fix_matches (id, session_id, slots) VALUES (${fm.id}, ${id}, ${fm.slots})
        ON CONFLICT (id) DO NOTHING
      `
    }

    await sql`DELETE FROM absent_players WHERE session_id = ${id}`
    for (const playerId of data.absentPlayers ?? []) {
      await sql`
        INSERT INTO absent_players (session_id, player_id) VALUES (${id}, ${playerId})
        ON CONFLICT DO NOTHING
      `
    }

    await sql`UPDATE sessions SET updated_at = ${now} WHERE id = ${id}`
    return send(res, null)
  }

  return sendError(res, 'Method not allowed', 405)
}
```

- [ ] **Step 2: Test with curl (dev server needs to be running via `vercel dev`)**

```bash
# Start local Vercel dev (reads .env.local automatically)
npx vercel dev

# In another terminal — list sessions (empty at first)
curl -H "Authorization: Bearer dev-secret" http://localhost:3000/api/sessions
# Expected: {"ok":true,"data":[]}
```

- [ ] **Step 3: Commit**

```bash
git add api/sessions.ts
git commit -m "feat: add GET/POST /api/sessions"
```

---

## Task 4: GET `/api/session` (full CloudSnapshot)

**Files:**
- Create: `api/session.ts`

- [ ] **Step 1: Create the handler**

Create `api/session.ts`:

```ts
import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'
import type { CloudSnapshot } from '../src/queries/types'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'GET') return sendError(res, 'Method not allowed', 405)

  const id = req.query.id as string
  if (!id) return sendError(res, 'Missing id', 400)

  const sql = getDb()

  const [sessionRows, playerRows, gameRows, fixRows, absentRows] = await Promise.all([
    sql`SELECT * FROM sessions WHERE id = ${id}`,
    sql`SELECT * FROM session_players WHERE session_id = ${id}`,
    sql`SELECT * FROM games WHERE session_id = ${id} ORDER BY slot, court`,
    sql`SELECT * FROM fix_matches WHERE session_id = ${id}`,
    sql`SELECT player_id FROM absent_players WHERE session_id = ${id}`,
  ])

  if (!sessionRows.length) return send(res, null)

  const s = sessionRows[0]
  const snapshot: CloudSnapshot = {
    session: {
      title: s.title ?? '',
      date: String(s.date).slice(0, 10),
      courts: (s.slots_per_court as number[]).length,
      sessionStart: s.session_start,
      slotMinutes: s.slot_minutes,
      courtTimes: s.court_times as { start: string; end: string }[],
      playerCount: playerRows.length,
      slotsPerCourt: s.slots_per_court as number[],
      totalGames: gameRows.length,
      courtNames: s.court_names as string[],
      tierCount: s.tier_count ?? 4,
      locked: true,
    },
    players: playerRows.map((p) => ({
      id: p.id,
      name: p.name,
      gender: p.gender as 'M' | 'F',
      tier: p.tier as 1 | 2 | 3 | 4,
    })),
    fixMatches: fixRows.map((f) => ({ id: f.id, slots: f.slots as [string, string, string, string] })),
    schedule: gameRows.map((g) => ({
      slot: g.slot,
      court: g.court,
      teamA: [g.team_a_p1, g.team_a_p2] as [string, string],
      teamB: [g.team_b_p1, g.team_b_p2] as [string, string],
    })),
    playedGames: gameRows.filter((g) => g.played).map((g) => `${g.slot}-${g.court}`),
    gameScores: Object.fromEntries(
      gameRows
        .filter((g) => g.score_a != null)
        .map((g) => [`${g.slot}-${g.court}`, { a: g.score_a as number, b: g.score_b as number }])
    ),
    absentPlayers: absentRows.map((r) => r.player_id),
  }

  return send(res, snapshot)
}
```

- [ ] **Step 2: Test**

```bash
# First create a test session via POST /api/sessions, then:
curl -H "Authorization: Bearer dev-secret" "http://localhost:3000/api/session?id=TEST_ID"
# Expected: {"ok":true,"data":{ ...CloudSnapshot }}
```

- [ ] **Step 3: Commit**

```bash
git add api/session.ts
git commit -m "feat: add GET /api/session returning CloudSnapshot"
```

---

## Task 5: PATCH `/api/game-played` and PATCH `/api/game-score`

**Files:**
- Create: `api/game-played.ts`
- Create: `api/game-score.ts`

- [ ] **Step 1: Create game-played handler**

Create `api/game-played.ts`:

```ts
import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'PATCH') return sendError(res, 'Method not allowed', 405)

  const { sessionId, gameId, played } = req.body as {
    sessionId: string
    gameId: string
    played: boolean
  }
  if (!sessionId || !gameId) return sendError(res, 'Missing fields', 400)

  const sql = getDb()
  const id = `${sessionId}-${gameId}`
  await sql`UPDATE games SET played = ${played} WHERE id = ${id}`
  return send(res, null)
}
```

- [ ] **Step 2: Create game-score handler**

Create `api/game-score.ts`:

```ts
import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'PATCH') return sendError(res, 'Method not allowed', 405)

  const { sessionId, gameId, a, b } = req.body as {
    sessionId: string
    gameId: string
    a: number
    b: number
  }
  if (!sessionId || !gameId || a == null || b == null) return sendError(res, 'Missing fields', 400)

  const sql = getDb()
  const id = `${sessionId}-${gameId}`
  await sql`UPDATE games SET score_a = ${a}, score_b = ${b}, played = true WHERE id = ${id}`
  return send(res, null)
}
```

- [ ] **Step 3: Test both**

```bash
curl -X PATCH http://localhost:3000/api/game-played \
  -H "Authorization: Bearer dev-secret" \
  -H "Content-Type: application/json" \
  -d '{"sessionId":"TEST_ID","gameId":"0-0","played":true}'
# Expected: {"ok":true,"data":null}

curl -X PATCH http://localhost:3000/api/game-score \
  -H "Authorization: Bearer dev-secret" \
  -H "Content-Type: application/json" \
  -d '{"sessionId":"TEST_ID","gameId":"0-0","a":30,"b":21}'
# Expected: {"ok":true,"data":null}
```

- [ ] **Step 4: Commit**

```bash
git add api/game-played.ts api/game-score.ts
git commit -m "feat: add PATCH /api/game-played and /api/game-score"
```

---

## Task 6: POST `/api/swap-players`

**Files:**
- Create: `api/swap-players.ts`

- [ ] **Step 1: Create the handler**

The swap target is `{ slot, court, playerId, team: 'A'|'B', index: 0|1 }`. We swap the player ID in the column determined by `team+index` between two game rows. If both targets are in the same game, it's a single-row update.

Create `api/swap-players.ts`:

```ts
import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError, colFromTarget } from './_db'

interface SwapTarget {
  slot: number
  court: number
  playerId: string
  team: 'A' | 'B'
  index: 0 | 1
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'POST') return sendError(res, 'Method not allowed', 405)

  const { sessionId, t1, t2 } = req.body as {
    sessionId: string
    t1: SwapTarget
    t2: SwapTarget
  }
  if (!sessionId || !t1 || !t2) return sendError(res, 'Missing fields', 400)

  const sql = getDb()
  const id1 = `${sessionId}-${t1.slot}-${t1.court}`
  const id2 = `${sessionId}-${t2.slot}-${t2.court}`
  const col1 = colFromTarget(t1.team, t1.index)
  const col2 = colFromTarget(t2.team, t2.index)
  const sameGame = id1 === id2

  if (sameGame) {
    // Both in the same game — update one row swapping two columns.
    // Use raw query string since column names are dynamic.
    // col1 and col2 are from a controlled whitelist so safe to interpolate.
    const validCols = new Set(['team_a_p1', 'team_a_p2', 'team_b_p1', 'team_b_p2'])
    if (!validCols.has(col1) || !validCols.has(col2)) return sendError(res, 'Invalid target', 400)
    await sql`
      UPDATE games SET
        ${sql.unsafe(col1)} = ${t2.playerId},
        ${sql.unsafe(col2)} = ${t1.playerId}
      WHERE id = ${id1}
    `
  } else {
    const validCols = new Set(['team_a_p1', 'team_a_p2', 'team_b_p1', 'team_b_p2'])
    if (!validCols.has(col1) || !validCols.has(col2)) return sendError(res, 'Invalid target', 400)
    await sql`
      UPDATE games SET ${sql.unsafe(col1)} = ${t2.playerId} WHERE id = ${id1}
    `
    await sql`
      UPDATE games SET ${sql.unsafe(col2)} = ${t1.playerId} WHERE id = ${id2}
    `
  }

  return send(res, null)
}
```

- [ ] **Step 2: Test**

```bash
curl -X POST http://localhost:3000/api/swap-players \
  -H "Authorization: Bearer dev-secret" \
  -H "Content-Type: application/json" \
  -d '{"sessionId":"TEST_ID","t1":{"slot":0,"court":0,"playerId":"p1","team":"A","index":0},"t2":{"slot":1,"court":0,"playerId":"p2","team":"A","index":0}}'
# Expected: {"ok":true,"data":null}
# Verify in Neon dashboard that player IDs swapped
```

- [ ] **Step 3: Commit**

```bash
git add api/swap-players.ts
git commit -m "feat: add POST /api/swap-players"
```

---

## Task 7: POST `/api/swap-slots`

**Files:**
- Create: `api/swap-slots.ts`

- [ ] **Step 1: Create the handler**

Swapping slots means swapping all content (players + played + scores) between two game rows. The game IDs (and slot/court columns) stay fixed — only the content moves. We fetch both rows, then update each row with the other's content in a single CASE WHEN statement.

Create `api/swap-slots.ts`:

```ts
import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'

interface SlotSwapTarget { slot: number; court: number }

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'POST') return sendError(res, 'Method not allowed', 405)

  const { sessionId, g1, g2 } = req.body as {
    sessionId: string
    g1: SlotSwapTarget
    g2: SlotSwapTarget
  }
  if (!sessionId || !g1 || !g2) return sendError(res, 'Missing fields', 400)

  const sql = getDb()
  const id1 = `${sessionId}-${g1.slot}-${g1.court}`
  const id2 = `${sessionId}-${g2.slot}-${g2.court}`

  const rows = await sql`SELECT * FROM games WHERE id IN (${id1}, ${id2})`
  if (rows.length !== 2) return sendError(res, 'Games not found', 404)

  const row1 = rows.find((r) => r.id === id1)!
  const row2 = rows.find((r) => r.id === id2)!

  // Swap all content between the two rows atomically
  await sql`
    UPDATE games SET
      team_a_p1 = CASE id WHEN ${id1} THEN ${row2.team_a_p1} ELSE ${row1.team_a_p1} END,
      team_a_p2 = CASE id WHEN ${id1} THEN ${row2.team_a_p2} ELSE ${row1.team_a_p2} END,
      team_b_p1 = CASE id WHEN ${id1} THEN ${row2.team_b_p1} ELSE ${row1.team_b_p1} END,
      team_b_p2 = CASE id WHEN ${id1} THEN ${row2.team_b_p2} ELSE ${row1.team_b_p2} END,
      played    = CASE id WHEN ${id1} THEN ${row2.played}    ELSE ${row1.played}    END,
      score_a   = CASE id WHEN ${id1} THEN ${row2.score_a}   ELSE ${row1.score_a}   END,
      score_b   = CASE id WHEN ${id1} THEN ${row2.score_b}   ELSE ${row1.score_b}   END
    WHERE id IN (${id1}, ${id2})
  `

  return send(res, null)
}
```

- [ ] **Step 2: Test**

```bash
curl -X POST http://localhost:3000/api/swap-slots \
  -H "Authorization: Bearer dev-secret" \
  -H "Content-Type: application/json" \
  -d '{"sessionId":"TEST_ID","g1":{"slot":0,"court":0},"g2":{"slot":1,"court":0}}'
# Expected: {"ok":true,"data":null}
```

- [ ] **Step 3: Commit**

```bash
git add api/swap-slots.ts
git commit -m "feat: add POST /api/swap-slots"
```

---

## Task 8: PUT `/api/absent` and PATCH `/api/replace-player`

**Files:**
- Create: `api/absent.ts`
- Create: `api/replace-player.ts`

- [ ] **Step 1: Create absent handler**

Create `api/absent.ts`:

```ts
import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'PUT') return sendError(res, 'Method not allowed', 405)

  const { sessionId, playerIds } = req.body as {
    sessionId: string
    playerIds: string[]
  }
  if (!sessionId || !Array.isArray(playerIds)) return sendError(res, 'Missing fields', 400)

  const sql = getDb()
  await sql`DELETE FROM absent_players WHERE session_id = ${sessionId}`
  for (const playerId of playerIds) {
    await sql`
      INSERT INTO absent_players (session_id, player_id) VALUES (${sessionId}, ${playerId})
      ON CONFLICT DO NOTHING
    `
  }
  return send(res, null)
}
```

- [ ] **Step 2: Create replace-player handler**

Create `api/replace-player.ts`:

```ts
import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'PATCH') return sendError(res, 'Method not allowed', 405)

  const { sessionId, playerId, newName } = req.body as {
    sessionId: string
    playerId: string
    newName: string
  }
  if (!sessionId || !playerId || !newName) return sendError(res, 'Missing fields', 400)

  const sql = getDb()
  await sql`
    UPDATE session_players SET name = ${newName}
    WHERE id = ${playerId} AND session_id = ${sessionId}
  `
  return send(res, null)
}
```

- [ ] **Step 3: Commit**

```bash
git add api/absent.ts api/replace-player.ts
git commit -m "feat: add PUT /api/absent and PATCH /api/replace-player"
```

---

## Task 9: GET `/api/players` and GET `/api/player-stats`

**Files:**
- Create: `api/players.ts`
- Create: `api/player-stats.ts`

- [ ] **Step 1: Create players list handler**

Create `api/players.ts`:

```ts
import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'
import type { PlayerSummary } from '../src/queries/types'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'GET') return sendError(res, 'Method not allowed', 405)

  const sql = getDb()
  // Most recent tier/gender per unique name
  const rows = await sql`
    SELECT DISTINCT ON (name) name, gender, tier
    FROM session_players
    ORDER BY name, session_id DESC
  `
  const data: PlayerSummary[] = rows.map((r) => ({
    name: r.name,
    gender: r.gender as 'M' | 'F',
    tier: r.tier as 1 | 2 | 3 | 4,
  }))
  return send(res, data)
}
```

- [ ] **Step 2: Create player-stats handler**

Create `api/player-stats.ts`:

```ts
import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'
import type { PlayerStats } from '../src/queries/types'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'GET') return sendError(res, 'Method not allowed', 405)

  const name = req.query.name as string
  if (!name) return sendError(res, 'Missing name', 400)

  const sql = getDb()

  // All games this player appeared in
  const gameRows = await sql`
    SELECT g.*, s.date, s.title, s.id AS sid,
      sp.id AS target_id
    FROM games g
    JOIN session_players sp ON sp.id IN (g.team_a_p1, g.team_a_p2, g.team_b_p1, g.team_b_p2)
    JOIN sessions s ON s.id = g.session_id
    WHERE sp.name ILIKE ${name} AND g.played = true
  `

  // All player names we need to resolve
  const allPlayerIds = new Set<string>()
  for (const g of gameRows) {
    for (const col of ['team_a_p1', 'team_a_p2', 'team_b_p1', 'team_b_p2'] as const) {
      if (g[col]) allPlayerIds.add(g[col])
    }
  }
  const playerRows = allPlayerIds.size
    ? await sql`SELECT id, name FROM session_players WHERE id IN ${sql(Array.from(allPlayerIds))}`
    : []
  const nameMap = new Map<string, string>(playerRows.map((p: { id: string; name: string }) => [p.id, p.name]))

  const partnerCount = new Map<string, { count: number; wins: number; losses: number }>()
  const opponentCount = new Map<string, { count: number; wins: number; losses: number }>()
  const sessionSet = new Map<string, { id: string; date: string; title: string }>()
  let gamesPlayed = 0, wins = 0, losses = 0, pointsFor = 0, pointsAgainst = 0

  for (const g of gameRows) {
    const targetId = g.target_id as string
    const onTeamA = [g.team_a_p1, g.team_a_p2].includes(targetId)
    const myTeam = onTeamA ? [g.team_a_p1, g.team_a_p2] : [g.team_b_p1, g.team_b_p2]
    const oppTeam = onTeamA ? [g.team_b_p1, g.team_b_p2] : [g.team_a_p1, g.team_a_p2]
    const myScore = onTeamA ? (g.score_a ?? 0) : (g.score_b ?? 0)
    const oppScore = onTeamA ? (g.score_b ?? 0) : (g.score_a ?? 0)
    const won = myScore > oppScore

    gamesPlayed++
    if (won) wins++; else losses++
    pointsFor += myScore
    pointsAgainst += oppScore

    sessionSet.set(g.sid, { id: g.sid, date: String(g.date).slice(0, 10), title: g.title })

    for (const pid of myTeam) {
      if (!pid || pid === targetId) continue
      const pname = nameMap.get(pid) ?? pid
      const entry = partnerCount.get(pname) ?? { count: 0, wins: 0, losses: 0 }
      entry.count++; if (won) entry.wins++; else entry.losses++
      partnerCount.set(pname, entry)
    }
    for (const pid of oppTeam) {
      if (!pid) continue
      const pname = nameMap.get(pid) ?? pid
      const entry = opponentCount.get(pname) ?? { count: 0, wins: 0, losses: 0 }
      entry.count++; if (won) entry.wins++; else entry.losses++
      opponentCount.set(pname, entry)
    }
  }

  const toSorted = (m: Map<string, { count: number; wins: number; losses: number }>) =>
    Array.from(m.entries())
      .map(([n, v]) => ({ name: n, ...v }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 10)

  const data: PlayerStats = {
    name,
    gamesPlayed,
    wins,
    losses,
    pointsFor,
    pointsAgainst,
    sessions: Array.from(sessionSet.values()).sort((a, b) => b.date.localeCompare(a.date)),
    topPartners: toSorted(partnerCount),
    topOpponents: toSorted(opponentCount),
  }

  return send(res, data)
}
```

- [ ] **Step 3: Test**

```bash
curl -H "Authorization: Bearer dev-secret" "http://localhost:3000/api/players"
# Expected: {"ok":true,"data":[...PlayerSummary]}

curl -H "Authorization: Bearer dev-secret" "http://localhost:3000/api/player-stats?name=Rakha"
# Expected: {"ok":true,"data":{gamesPlayed:...,topPartners:[...],...}}
```

- [ ] **Step 4: Commit**

```bash
git add api/players.ts api/player-stats.ts
git commit -m "feat: add GET /api/players and /api/player-stats"
```

---

## Task 10: GET + PUT `/api/tournament`

**Files:**
- Create: `api/tournament.ts`

- [ ] **Step 1: Create the handler**

Create `api/tournament.ts`:

```ts
import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'
import type { TournamentSnapshot } from '../src/queries/types'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)

  const sql = getDb()

  if (req.method === 'GET') {
    const id = req.query.id as string
    if (!id) return sendError(res, 'Missing id', 400)
    const rows = await sql`SELECT data FROM tournaments WHERE id = ${id}`
    if (!rows.length) return send(res, null)
    return send(res, rows[0].data as TournamentSnapshot)
  }

  if (req.method === 'PUT') {
    const { id, data } = req.body as { id: string; data: TournamentSnapshot }
    if (!id || !data) return sendError(res, 'Missing fields', 400)
    const now = new Date().toISOString()
    await sql`
      INSERT INTO tournaments (id, data, created_at, updated_at)
      VALUES (${id}, ${JSON.stringify(data)}, ${now}, ${now})
      ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data, updated_at = EXCLUDED.updated_at
    `
    return send(res, null)
  }

  return sendError(res, 'Method not allowed', 405)
}
```

- [ ] **Step 2: Commit**

```bash
git add api/tournament.ts
git commit -m "feat: add GET/PUT /api/tournament"
```

---

## Task 11: Migration script

**Files:**
- Create: `scripts/migrate-to-postgres.mjs`

- [ ] **Step 1: Create the script**

Create `scripts/migrate-to-postgres.mjs`:

```js
import { neon } from '@neondatabase/serverless'
import { readFileSync } from 'fs'

// Load env from .env.local
const envFile = readFileSync(new URL('../.env.local', import.meta.url), 'utf8')
for (const line of envFile.split('\n')) {
  const [key, ...rest] = line.split('=')
  if (key && rest.length) process.env[key.trim()] = rest.join('=').trim()
}

const APPS_SCRIPT_URL = process.env.VITE_APPS_SCRIPT_URL
const sql = neon(process.env.DATABASE_URL)

async function fetchJson(url) {
  const res = await fetch(url)
  return res.json()
}

async function migrateSession(id) {
  console.log(`  Migrating session ${id}...`)
  const { ok, data } = await fetchJson(`${APPS_SCRIPT_URL}?id=${encodeURIComponent(id)}`)
  if (!ok || !data) { console.log(`  SKIP ${id} — not found`); return }

  const s = data.session
  const now = new Date().toISOString()

  await sql`
    INSERT INTO sessions (id, title, date, session_start, slot_minutes, slots_per_court, court_names, court_times, tier_count, created_at, updated_at)
    VALUES (${id}, ${s.title}, ${s.date}, ${s.sessionStart}, ${s.slotMinutes},
      ${s.slotsPerCourt}, ${s.courtNames ?? []}, ${JSON.stringify(s.courtTimes)},
      ${s.tierCount ?? 4}, ${now}, ${now})
    ON CONFLICT (id) DO NOTHING
  `

  for (const p of data.players ?? []) {
    await sql`
      INSERT INTO session_players (id, session_id, name, gender, tier)
      VALUES (${p.id}, ${id}, ${p.name}, ${p.gender}, ${p.tier})
      ON CONFLICT (id) DO NOTHING
    `
  }

  const playedSet = new Set(data.playedGames ?? [])
  for (const g of data.schedule ?? []) {
    const gid = `${id}-${g.slot}-${g.court}`
    const key = `${g.slot}-${g.court}`
    const score = data.gameScores?.[key]
    const played = playedSet.has(key)
    await sql`
      INSERT INTO games (id, session_id, slot, court, team_a_p1, team_a_p2, team_b_p1, team_b_p2, played, score_a, score_b)
      VALUES (${gid}, ${id}, ${g.slot}, ${g.court}, ${g.teamA[0]}, ${g.teamA[1]}, ${g.teamB[0]}, ${g.teamB[1]},
        ${played}, ${score?.a ?? null}, ${score?.b ?? null})
      ON CONFLICT (id) DO NOTHING
    `
  }

  for (const fm of data.fixMatches ?? []) {
    await sql`
      INSERT INTO fix_matches (id, session_id, slots) VALUES (${fm.id}, ${id}, ${fm.slots})
      ON CONFLICT (id) DO NOTHING
    `
  }

  for (const playerId of data.absentPlayers ?? []) {
    await sql`
      INSERT INTO absent_players (session_id, player_id) VALUES (${id}, ${playerId})
      ON CONFLICT DO NOTHING
    `
  }

  console.log(`  ✓ ${id} — ${data.schedule?.length ?? 0} games, ${data.players?.length ?? 0} players`)
}

async function main() {
  console.log('Fetching session list from Apps Script...')
  const { ok, data: sessions } = await fetchJson(`${APPS_SCRIPT_URL}?action=list`)
  if (!ok) throw new Error('Failed to list sessions')
  console.log(`Found ${sessions.length} sessions`)

  for (const meta of sessions) {
    await migrateSession(meta.id)
  }

  // Migrate tournament
  const TOURNAMENT_ID = 'tournament-2026-05-23-majadu'
  console.log(`\nMigrating tournament ${TOURNAMENT_ID}...`)
  const { ok: tok, data: tdata } = await fetchJson(
    `${APPS_SCRIPT_URL}?action=getTournament&id=${encodeURIComponent(TOURNAMENT_ID)}`
  )
  if (tok && tdata) {
    const now = new Date().toISOString()
    await sql`
      INSERT INTO tournaments (id, data, created_at, updated_at)
      VALUES (${TOURNAMENT_ID}, ${JSON.stringify(tdata)}, ${now}, ${now})
      ON CONFLICT (id) DO NOTHING
    `
    console.log('✓ Tournament migrated')
  } else {
    console.log('No tournament data found, skipping')
  }

  console.log('\nMigration complete!')
}

main().catch((e) => { console.error(e); process.exit(1) })
```

- [ ] **Step 2: Run the migration**

Make sure `.env.local` has both `DATABASE_URL` and `VITE_APPS_SCRIPT_URL` set, then:

```bash
node scripts/migrate-to-postgres.mjs
```

Expected output:
```
Fetching session list from Apps Script...
Found 12 sessions
  Migrating session 4dkf26...
  ✓ 4dkf26 — 15 games, 20 players
  ...
✓ Tournament migrated
Migration complete!
```

- [ ] **Step 3: Verify in Neon dashboard**

Open Neon SQL Editor and run:

```sql
SELECT COUNT(*) FROM sessions;      -- should be 12
SELECT COUNT(*) FROM games;         -- should be total games across all sessions
SELECT COUNT(*) FROM session_players;
```

- [ ] **Step 4: Commit**

```bash
git add scripts/migrate-to-postgres.mjs
git commit -m "feat: add one-time migration script from Apps Script to Postgres"
```

---

## Task 12: Update frontend — `endpoints.ts` and `sessions.ts`

**Files:**
- Modify: `src/queries/endpoints.ts`
- Modify: `src/queries/sessions.ts`

- [ ] **Step 1: Rewrite `src/queries/endpoints.ts`**

Replace the entire file with:

```ts
import type { CloudSnapshot, SessionMeta, PlayerSummary, PlayerStats } from './types'
import type { TournamentSnapshot } from '../utils/tournament'

export const TOURNAMENT_ID = 'tournament-2026-05-23-majadu'

function apiUrl(): string {
  return (import.meta.env.VITE_API_URL as string) ?? ''
}

function authHeader(): HeadersInit {
  return { Authorization: `Bearer ${import.meta.env.VITE_API_TOKEN as string}` }
}

async function apiFetch<T>(url: string, init?: RequestInit): Promise<T> {
  const res = await fetch(url, { ...init, headers: { ...authHeader(), ...init?.headers } })
  const json = await res.json() as { ok: boolean; data?: T; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'API error')
  return json.data as T
}

export async function getSession(id: string): Promise<CloudSnapshot | null> {
  return apiFetch<CloudSnapshot | null>(`${apiUrl()}/api/session?id=${encodeURIComponent(id)}`)
}

export async function publishSession(id: string, data: CloudSnapshot): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id, data }),
  })
}

export async function listSessions(): Promise<SessionMeta[]> {
  return apiFetch<SessionMeta[]>(`${apiUrl()}/api/sessions`)
}

export async function listPlayers(): Promise<PlayerSummary[]> {
  return apiFetch<PlayerSummary[]>(`${apiUrl()}/api/players`)
}

export async function getPlayerStats(name: string): Promise<PlayerStats> {
  return apiFetch<PlayerStats>(`${apiUrl()}/api/player-stats?name=${encodeURIComponent(name)}`)
}

export async function getTournament(id: string): Promise<TournamentSnapshot | null> {
  return apiFetch<TournamentSnapshot | null>(`${apiUrl()}/api/tournament?id=${encodeURIComponent(id)}`)
}

export async function publishTournament(id: string, data: TournamentSnapshot): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/tournament`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id, data }),
  })
}

// Targeted mutation helpers (used by hooks in sessions.ts)
export async function setGamePlayed(sessionId: string, gameId: string, played: boolean): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/game-played`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId, gameId, played }),
  })
}

export async function setGameScore(sessionId: string, gameId: string, a: number, b: number): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/game-score`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId, gameId, a, b }),
  })
}

export async function swapPlayers(sessionId: string, t1: unknown, t2: unknown): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/swap-players`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId, t1, t2 }),
  })
}

export async function swapSlots(sessionId: string, g1: unknown, g2: unknown): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/swap-slots`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId, g1, g2 }),
  })
}

export async function setAbsent(sessionId: string, playerIds: string[]): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/absent`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId, playerIds }),
  })
}

export async function replacePlayer(sessionId: string, playerId: string, newName: string): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/replace-player`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId, playerId, newName }),
  })
}
```

- [ ] **Step 2: Update `src/queries/sessions.ts` — replace mutationFns**

In `src/queries/sessions.ts`, update the imports at the top:

```ts
import {
  getSession, publishSession, listSessions,
  setGamePlayed, setGameScore, swapPlayers as swapPlayersApi,
  swapSlots as swapSlotsApi, setAbsent as setAbsentApi, replacePlayer as replacePlayerApi,
} from './endpoints'
```

Then update each `mutationFn` (the `onMutate`/`onError`/`onSettled` logic stays the same):

In `useTogglePlayed`, replace the `mutationFn`:
```ts
mutationFn: async ({ key, nextPlayed }: { key: string; nextPlayed: string[] }) => {
  const played = nextPlayed.includes(key)
  await setGamePlayed(sessionId, key, played)
},
```

In `useSetScore`, replace the `mutationFn`:
```ts
mutationFn: async ({ key, a, b }: { key: string; a: number; b: number }) => {
  await setGameScore(sessionId, key, a, b)
},
```

In `useSwapPlayers`, replace the `mutationFn`:
```ts
mutationFn: async ({ t1, t2 }: { t1: SwapTarget; t2: SwapTarget }) => {
  await swapPlayersApi(sessionId, t1, t2)
},
```

In `useSetAbsent`, replace the `mutationFn`:
```ts
mutationFn: async ({ nextAbsent }: { nextAbsent: string[] }) => {
  await setAbsentApi(sessionId, nextAbsent)
},
```

In `useReplacePlayer`, replace the `mutationFn`:
```ts
mutationFn: async ({ playerId, newName }: { playerId: string; newName: string }) => {
  await replacePlayerApi(sessionId, playerId, newName)
},
```

In `useSwapSlots`, replace the `mutationFn`:
```ts
mutationFn: async ({ g1, g2 }: { g1: SlotSwapTarget; g2: SlotSwapTarget }) => {
  await swapSlotsApi(sessionId, g1, g2)
},
```

- [ ] **Step 3: Update `.env` (local dev)**

Add to `.env` (local):
```env
VITE_API_URL=http://localhost:3000
VITE_API_TOKEN=dev-secret
```

Remove or comment out `VITE_APPS_SCRIPT_URL`.

- [ ] **Step 4: Type-check**

```bash
npm run build
```

Expected: no TypeScript errors, builds successfully.

- [ ] **Step 5: Commit**

```bash
git add src/queries/endpoints.ts src/queries/sessions.ts .env
git commit -m "feat: update frontend queries to use new Vercel Function API"
```

---

## Task 13: Deploy and smoke test

**Files:**
- No new files — deploy existing changes

- [ ] **Step 1: Add env vars to Vercel**

In Vercel dashboard → project → Settings → Environment Variables, add:
- `DATABASE_URL` = your Neon pooled connection string
- `API_TOKEN` = same secret used in migration

Also update frontend env in Vercel:
- `VITE_API_URL` = `https://<your-project>.vercel.app`
- `VITE_API_TOKEN` = same secret

- [ ] **Step 2: Push branch and deploy**

```bash
git push origin feat/vercel-postgres-backend
```

Vercel will auto-deploy. Wait for build to complete.

- [ ] **Step 3: Smoke test production**

```bash
export BASE=https://<your-project>.vercel.app
export TOKEN=<your-secret>

# List sessions
curl -H "Authorization: Bearer $TOKEN" "$BASE/api/sessions"
# Expected: 12 sessions from migration

# Get a specific session
curl -H "Authorization: Bearer $TOKEN" "$BASE/api/session?id=4dkf26"
# Expected: full CloudSnapshot with schedule, players, scores

# Player stats
curl -H "Authorization: Bearer $TOKEN" "$BASE/api/player-stats?name=Rakha"
# Expected: gamesPlayed > 0, topPartners populated
```

- [ ] **Step 4: Test the app UI end-to-end**

1. Open the deployed URL in browser
2. Navigate to Sessions list — should show 12 past sessions
3. Open a session — should show schedule with scores
4. Toggle a game as played — check Neon dashboard that `played` column updated
5. Enter a score — check `score_a`/`score_b` updated in DB
6. Open Player History — should list all players
7. Open a player detail — should show career stats

- [ ] **Step 5: Commit final state**

```bash
git add .
git commit -m "feat: complete backend migration to Vercel Functions + Neon Postgres"
```
