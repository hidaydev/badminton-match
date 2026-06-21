# Manual Cleanup RPCs

Last updated: 2026-06-21

Two maintenance RPCs for manually cleaning up test data via Supabase SQL
Editor. These are **destructive** and **not exposed** to the app — only
`service_role` and `postgres` can call them.

## Migration

- [`supabase/migrations/20260618_000038_bm_cleanup_rpcs.sql`](../../supabase/migrations/20260618_000038_bm_cleanup_rpcs.sql)

Apply via Supabase SQL Editor if not already applied.

## bm.delete_session(p_lookup text)

Deletes a session and all its child data (courts, players, fix matches,
scheduled games, scores, progress). Cascades handle everything.

**Parameters:**
- `p_lookup` — session id, share_id, or internal_id (uuid)

**Returns:** JSON summary of what was deleted.

**Usage in SQL Editor:**

```sql
-- Delete by session id (the short code like 'rp9ewb')
SELECT bm.delete_session('rp9ewb');

-- Delete by share_id
SELECT bm.delete_session('rp9ewb');

-- Delete by internal_id (uuid)
SELECT bm.delete_session('a1b2c3d4-...');
```

**Example output:**
```json
{
  "deleted": true,
  "sessionId": "rp9ewb",
  "shareId": "rp9ewb",
  "internalId": "03ffef92-abdf-47c4-ba75-77873fcd6bb9",
  "courts": 2,
  "players": 8,
  "fixMatches": 0,
  "games": 6
}
```

**Error cases:**
- Blank lookup → `session lookup must not be blank`
- Not found → `session not found: <lookup>`

---

## bm.delete_player(p_name text, p_force boolean default false)

Deletes a player and all their aliases. If the player is referenced in any
session's `session_players`, deletion is blocked unless `p_force=true`.

**Parameters:**
- `p_name` — player name or alias (normalized case-insensitive)
- `p_force` — if `true`, also removes `session_players` rows for this player
  (cascade cleans `fix_match_slots` via SET NULL, `scheduled_game_players`
  via CASCADE). Default `false`.

**Returns:** JSON summary of what was deleted.

**Usage in SQL Editor:**

```sql
-- Safe delete (blocks if player is in any session)
SELECT bm.delete_player('Budi');

-- Force delete (removes session references too)
SELECT bm.delete_player('Budi', true);
```

**Example output:**
```json
{
  "deleted": true,
  "playerId": "a814b8e7-7133-4f43-bf02-1ba7fa7a58d3",
  "canonicalName": "Budi",
  "aliases": 1,
  "sessionRefsRemoved": 0
}
```

**Error cases:**
- Blank name → `player name must not be blank`
- Not found → `player not found: <name>`
- Referenced without force → `player X is referenced in N session(s). Use p_force=true to remove. References: [...]`

---

## Typical Test Cleanup Workflow

```sql
-- 1. List sessions to find test data
SELECT id, title, session_date, version
FROM bm.sessions
ORDER BY session_date DESC;

-- 2. Delete test sessions
SELECT bm.delete_session('__test_session_id__');

-- 3. List players to find test players
SELECT p.canonical_name, p.id,
       (SELECT count(*) FROM bm.session_players sp WHERE sp.player_id = p.id) as session_count
FROM bm.players p
ORDER BY p.canonical_name;

-- 4. Delete test players (safe — will block if still referenced)
SELECT bm.delete_player('__test_player_name__');

-- 5. If blocked, either delete the session first (step 2) or force delete
SELECT bm.delete_player('__test_player_name__', true);
```

## Security

Both functions are `security definer` (run as postgres owner) with
`set search_path = bm, public`. Granted only to `service_role` —
explicitly revoked from `anon` and `authenticated`. The Supabase SQL
Editor runs as `postgres`/`supabase_admin` which can call any function.

These RPCs are **not callable** from the app frontend (anon key).
