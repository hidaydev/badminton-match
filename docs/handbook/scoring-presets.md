# Scoring Presets (per-session score format)

Status: **implemented**. Migrations `0029`/`0030` have run; this document
explains the rules and the numbers, not a plan.
Date: 2026-11-06
Scope: per-session score format (single game / best-of-3) in Majadu v2.
Out of scope: tournaments and custom presets by admins.

---

## Table of contents

1. Summary
2. Glossary: what "rating" is and where it is used
3. Today's scoring architecture (facts + line numbers)
4. Decisions already locked
5. Configuration
6. Data model
7. Scoring rules engine (pure module)
8. Write path & read path
9. API & contract
10. Impact on point calculation (rating)
11. Number simulations
12. Standings
13. Achievement, share, export
14. UI: wizard, set editor, compact display
15. Work phases & acceptance criteria
16. Test plan
17. Risks, rollback, and deferred items
18. List of files touched
19. Open questions

---

## 1. Summary

The three presets in the image are not just "play up to some number of points". All
three are **match formats**:

| Preset | Match | Sets to win | Points | Deuce | Cap | Change ends |
|---|---|---|---|---|---|---|
| MAJADU 30 | 1 set | 1 | 30 | none | 30 | 15 |
| Classic BO3 21 | best of 3 | 2 | 21 | 20–20 | 30 | 11 |
| New BWF BO3 15 | best of 3 | 2 | 15 | 14–14 | 21 | 8 |

The current model stores **one score pair per slot** (`session.games.score_a/score_b`).
That cannot hold BO3: the second and third set scores have nowhere to go, and
`gamesToWin` would only become a label.

So the core change is:

> one slot (round, court) = one match; one match contains 1..3 sets;
> sets are stored in the new table `session.game_sets`; all readers use the view
> `session.game_results`, which exposes the winner, the sets, and total points.

Presets are stored as config (`session.scoring_presets`) and *snapshotted* into
each session. Changing the preset config in the future never rewrites
history; the only retroactive change is the 21 → 30 target fix in this
release.

Old sessions still read as one set, but their points are recomputed with
target 30 (the format that was actually played), so the board moves once at
release. For BO3, the margin is normalized per set so that one BO3 match is not
automatically worth three times one game.

Estimate: P0 1–2 days, P1 1 day, P2 1–2 days, P3 ½ day. Total 4–6 effective
working days, not counting design review.

---

## 2. Glossary: what "rating" is and where it is used

This question needs an answer first because the term really is confusing.

**There are not two systems.** Only one is used: **rank point**. In the code,
"rating" is the name of a module and of tables, not a separate ELO number.

Facts that can be checked:

- `rating.player_state` stores **counters**: `games_played`, `wins`, `losses`
  (`modules/rating/infrastructure/ledger.nim:48-60`). The `rating` column was
  dropped in migration `0026_drop_rating_ledger.sql`.
- Board points **are not stored**; they are recomputed every time they are read from
  `session.games` and `tournament.matches` (`modules/rating/projection.nim`).
- The only stored point number is the daily snapshot
  `rating.snapshots.rating` (`db/migrations/0002_rating.sql:56-64`), used
  for `prevRank`/`rankDelta` and the `rank_streak` badge.
- "Tier" (D, C, B, ...) is not derived from points. It is stored in `player.players.tier`
  and used as opponent strength (`tierStrength`, `opponentMultiplier`).

So the short answer is:

> rating = rank point. `rating.*` is only a module name. Points are computed when read,
> the daily snapshot stores the result so rank movement can be seen.

Where the numbers appear to users:

| Screen | Source |
|---|---|
| Leaderboard | `read.boardRows` → `projection.project` |
| Player profile (breakdown) | the same projection |
| `prevRank` / `rankDelta` | `rating.snapshots` |
| `rank:*`, `rank_streak:*` badges | `rating.snapshots` + `player_state` |
| Game/win/loss counts on the profile | `rating.player_state` |

Consequence for this feature: **the only place the match format touches points
is the `gameValue` formula** in the projection. There are no stored deltas that need
migrating.

---

## 3. Today's scoring architecture

Relevant facts (all already verified in the code):

- **One slot = one game.** `session.games` has `round_no`, `court_no`,
  `score_a`, `score_b`, `status` (`db/migrations/0001_core.sql:95-116`).
  Unique `(session_id, round_no, court_no)`; score 0..99; `games_not_tied`
  rejects a tie when `status='played'`.
- **Scores are written only in draft.** `gate()` rejects every write when the status is not
  `draft` (`modules/session/schedule.nim:97-111`). Writes use `If-Match`
  (session version), then `bump()` increments the version.
- **`setScore`** only accepts 0..99 and rejects ties
  (`modules/session/schedule.nim:249-283`).
- **`setPlayed`** may mark a game played **without a score** and delete an existing
  score (`schedule.nim:284-317`). That means `status='played'` is not proof that a
  match is finished.
- **Score readers** today:
  - `modules/session/standings.nim`: standings per session.
  - `modules/rating/projection.nim:186-246`: board points.
  - `modules/rating/infrastructure/ingest.nim:96-110`: game/win counters.
  - `modules/rating/read.nim:208-260`: history & most frequent opponents/partners.
  - `modules/achievement/infrastructure/backfill.nim:143-176`: volume badges.
  - `apps/api/src/app.nim`: session detail (`~2035`), game (`~2085`),
     share (`~2150`).
- **Rating uses target 21 for all sessions** (`rating.score_target`), even though
  sessions are played to 30. A 30–29 margin is already treated as full, and 30–5
  is saturated. This is the bug this feature fixes, and because points are computed when
  read, the fix applies retroactively.

Consequence: every reader above must move to one new source. If it
does not, BO3 will be read as "total points" and the winner could be wrong.

---

## 4. Decisions already locked

| # | Decision | Reason |
|---|---|---|
| 1 | BO3 rating normalization = average margin per set | Format-neutral; a single set is identical to the old formula |
| 2 | One BO3 match = **1 game** for standings & achievement | "Game" means a match played, not a set |
| 3 | The preset may be changed as long as no sets exist | Once a set exists, it must be cleared first |
| 4 | Only three official presets | A fourth preset = a config change, not a release |
| 5 | Tournaments are out of scope | Tournament formats have their own point rules |
| 6 | Per-set details are displayed | A 2–1 score without set details cannot be verified |
| 7 | Partial sets may be saved, not counted | Operators often fill in between sets |
| 8 | Old sessions are also rated with target 30 | Their format really is MAJADU 30; target 21 was a bug |

Note on #3: because all score writes are only allowed in `draft`, the
"no sets yet" rule is enough as an extra guard in `PATCH /sessions/{id}`.
Clearing the sets (body `{"sets": []}`) reopens the preset choice.

Note on #8: this decision is **retroactive**. Points of old sessions are recomputed
with target 30 when the board is read, because points really are not stored. The total
points of one match remain 250 (before the multiplier); what changes is the split
between winner and opponent. The consequences and the numbers are in §10–11.

---

## 5. Configuration

### 5.1 New keys

| Key | Type | Scope | Default | Bound | Purpose |
|---|---|---|---|---|---|
| `session.scoring_presets` | json | platform | 3 official presets | array 1..20 | Definition of the formats that may be selected |
| `session.default_scoring_preset` | string | **community** | `majadu30` | must be an existing id | Initial choice in the wizard |

Both go into `modules/platform/config/registry.nim`, `db/seeds/platform_config.sql`,
and the migration. `session.default_scoring_preset` is deliberately community-scoped so
one community can default to BWF without changing the platform default.

### 5.2 JSON shape

```json
[
  {
    "id": "majadu30",
    "label": "MAJADU 30",
    "gamesToWin": 1,
    "pointsToWin": 30,
    "winBy": 1,
    "deuceAt": null,
    "maxPoints": 30,
    "changeEndsAt": 15
  },
  {
    "id": "classic21",
    "label": "Classic BO3 21",
    "gamesToWin": 2,
    "pointsToWin": 21,
    "winBy": 2,
    "deuceAt": 20,
    "maxPoints": 30,
    "changeEndsAt": 11
  },
  {
    "id": "bwf15",
    "label": "New BWF BO3 15",
    "gamesToWin": 2,
    "pointsToWin": 15,
    "winBy": 2,
    "deuceAt": 14,
    "maxPoints": 21,
    "changeEndsAt": 8
  }
]
```

Fields:

- `id`: `[a-z0-9_]{2,32}`, unique, not `legacy_v1` (reserved).
- `label`: text displayed in the wizard; not translated (format name).
- `gamesToWin`: sets that must be won (1 = single match).
- `pointsToWin`: points to win a set without deuce.
- `winBy`: minimum difference; for MAJADU 30 the value is 1 (no deuce).
- `deuceAt`: the opponent's score at which the `winBy` rule starts to apply; `null` = there is
  no deuce.
- `maxPoints`: cap. Once the cap is reached, a difference of 1 is enough.
- `changeEndsAt`: a UI hint only ("change ends at 11"), it does not affect
  data or validation.

`ratingTarget` no longer exists: `pointsToWin` **is** the rating target.
`mode` is not written in the config either; presets from config are always `"preset"`, and
only the `legacy_v1` snapshot uses `"legacy"`.

### 5.3 Validation at load

`loadSnapshot` already refuses to start if a key is missing or has the wrong type. Add
validation for these JSON keys (function `parsePresets` in `modules/session/scoring.nim`,
called from `modules/platform/config/store.nim`):

| Rule | Message |
|---|---|
| array, length 1..20 | `session.scoring_presets must be a non-empty array (max 20)` |
| `id` matches the regex, unique, not `legacy_v1` | `duplicate preset id: x` |
| `gamesToWin` 1..5 | `preset x: gamesToWin must be 1..5` |
| `pointsToWin` 1..99 | `preset x: pointsToWin must be 1..99` |
| `winBy` 1..10 | `preset x: winBy must be 1..10` |
| `maxPoints` ≥ `pointsToWin`, ≤ 99 | `preset x: maxPoints must be at least pointsToWin` |
| `deuceAt` null or `pointsToWin-1 .. maxPoints-1` | `preset x: deuceAt is out of range` |
| `changeEndsAt` null or 1..`pointsToWin-1` | `preset x: changeEndsAt is out of range` |
| `default_scoring_preset` exists in the array | `default preset not found: x` |

All fail **at start**, not at request time. This is consistent with the repo's
config philosophy: no hidden defaults in code.

Community override validation happens in the settings route at write time:
`session.default_scoring_preset` must be an id that exists in the platform presets at that moment.
Otherwise → `400 INVALID_CONFIG`. There is no silent fallback in
`createSession`: an id that no longer exists in the config → `400 INVALID_PRESET`.
This prevents a session from being born with a format that cannot be explained to users.

### 5.4 Snapshot per session

`session.sessions` stores two columns:

- `scoring_preset text`: id.
- `scoring_rules jsonb`: full copy of the rules.

Snapshot example for a new session:

```json
{
  "id": "classic21",
  "label": "Classic BO3 21",
  "mode": "preset",
  "gamesToWin": 2,
  "pointsToWin": 21,
  "winBy": 2,
  "deuceAt": 20,
  "maxPoints": 30,
  "changeEndsAt": 11
}
```

Snapshot for an old session (created by the migration):

```json
{
  "id": "legacy_v1",
  "label": "v1 scoring",
  "mode": "legacy",
  "gamesToWin": 1,
  "pointsToWin": 30,
  "winBy": 1,
  "deuceAt": null,
  "maxPoints": 99,
  "changeEndsAt": 15
}
```

`mode: "legacy"` is the only special branch: set validation is only
"0..99 and not tied", exactly the v1 behaviour. Without this flag, reopening an old
session to fix a 21–19 score would be rejected by the 30-point rule.

**An old session = a MAJADU 30 session, so it is rated with target 30.** Previously
rating used `rating.score_target = 21`; that was a bug, and because points are not
stored, this fix automatically applies retroactively when the board is read. There is no
point migration; what needs to be understood is only the board movement (§10–11).

`legacy_v1` is **never** present in `session.scoring_presets`, so it
cannot be selected in the wizard and cannot be used by `PATCH`.

### 5.5 Why a snapshot, not a reference

If a session stored only the id, and an operator then changed `pointsToWin` or
deleted the preset, old sessions would change meaning (scores that used to be valid become
invalid, points change). A snapshot makes the rules part of the result data, the same
way `rating.events.local_date` stores the date when the result was locked.

Side effect: changing the preset config only affects **new** sessions.
That is intentional and needs to be mentioned in the handbook.

### 5.6 How the client reads the preset list

`session.scoring_presets` is a **platform** key, so it does not appear in
`effective` (which only contains community-scoped keys). The wizard needs the list
before a session is created.

Solution: `GET /c/{slug}/config` adds a **read-only** reference field:

```json
{
  "effective": { "...": "..." },
  "scoringPresets": [
    {"id": "majadu30", "label": "MAJADU 30", "gamesToWin": 1, "pointsToWin": 30,
     "winBy": 1, "deuceAt": null, "maxPoints": 30, "changeEndsAt": 15}
  ]
}
```

- Not a setting; it cannot be written through `PATCH /c/{slug}/settings`.
- Its content is the same for all communities; the per-community default is still taken from
  `effective["session.default_scoring_preset"]`.
- If presets later become allowed to differ per community, this field is what changes without
  changing the shape of `effective`.

On the client, `community/api.ts` (`fetchCommunityConfig`) and
`community/useCommunityConfig.ts` are extended to return
`{ effective, scoringPresets }`; the wizard and `SettingsPage` use the
same hook. This avoids a new endpoint and ensures both screens see an identical
list.

Parity consequence: one config case changes (new field). There is no new
operation; still 75 operations.

---

## 6. Data model

### 6.1 Migration `0029_scoring_presets.sql`

```sql
-- 0029: one slot is one match, and a match is a list of sets.
--
-- The flat score columns stay for one release: they are the backfill source
-- and the rollback path. Nothing writes them after this migration; every
-- reader moves to session.game_results.

alter table session.sessions
  add column scoring_preset text not null default 'legacy_v1',
  add column scoring_rules jsonb not null default '{
    "id": "legacy_v1",
    "label": "v1 scoring",
    "mode": "legacy",
    "gamesToWin": 1,
    "pointsToWin": 30,
    "winBy": 1,
    "deuceAt": null,
    "maxPoints": 99,
    "changeEndsAt": 15
  }'::jsonb;

alter table session.games
  add constraint games_identity_unique
  unique (community_id, session_id, round_no, court_no);

create table session.game_sets (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null,
  session_id uuid not null,
  round_no integer not null,
  court_no integer not null,
  set_no integer not null,
  score_a integer not null,
  score_b integer not null,
  created_at timestamptz not null default now(),
  constraint game_sets_match_fk
    foreign key (community_id, session_id, round_no, court_no)
    references session.games (community_id, session_id, round_no, court_no)
    on delete cascade,
  constraint game_sets_set_unique
    unique (session_id, round_no, court_no, set_no),
  constraint game_sets_set_no_check check (set_no between 1 and 9),
  constraint game_sets_score_range check (
    score_a between 0 and 99 and score_b between 0 and 99),
  constraint game_sets_not_tied check (score_a <> score_b)
);

insert into session.game_sets
  (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
select community_id, session_id, round_no, court_no, 1, score_a, score_b
from session.games
where score_a is not null and score_b is not null;
```

The configuration is part of the same migration (the `0028_config_cleanup.sql` pattern):

```sql
insert into platform.config
  (key, value_type, value, min_value, max_value, scope, description)
values
  ('session.scoring_presets', 'json',
   '[{"id":"majadu30",...},{"id":"classic21",...},{"id":"bwf15",...}]',
   null, null, 'platform', 'Selectable match formats'),
  ('session.default_scoring_preset', 'string', '"majadu30"',
   null, null, 'community', 'Format chosen by default in the session wizard')
on conflict (key) do update set
  value_type = excluded.value_type,
  value = excluded.value,
  min_value = excluded.min_value,
  max_value = excluded.max_value,
  scope = excluded.scope,
  description = excluded.description;

-- The session target now comes from each session's snapshot. Keep this key only
-- as a fallback, but make the fallback match the format people actually play.
update platform.config
   set value = '30'
 where key = 'rating.score_target';

update platform.config_version set version = version + 1;
```

The seed (`db/seeds/platform_config.sql`) uses the same values with
`on conflict do nothing`, so a new DB and an old DB end up identical.
`rating.score_target` in the seed also becomes 30.

Notes:

- `games_identity_unique` is required by PostgreSQL for the composite FK. `0041`
  drops the older `games_round_court_unique`; writers now name the composite key
  in `on conflict (community_id, session_id, round_no, court_no)`.
- `session_id` is already a global uuid, so `community_id` in the FK is an extra
  defence layer, not a technical requirement.
- The backfill only takes rows that have **both** scores. A `played` game
  without a score (the result of `setPlayed`) still has no sets, exactly as today
  it is not counted.
- The backfill does not touch `status`; a game that was `scheduled` but has a score
  (not possible through the API) is still included, and readers still filter by status.

### 6.2 View `session.game_results`

One source for all readers:

```sql
create view session.game_results as
select
  g.id,
  g.community_id,
  g.session_id,
  g.round_no,
  g.court_no,
  g.status,
  g.side_a1,
  g.side_a2,
  g.side_b1,
  g.side_b2,
  s.scoring_preset,
  (s.scoring_rules->>'gamesToWin')::int     as games_to_win,
  (s.scoring_rules->>'pointsToWin')::int    as points_to_win,
  coalesce(t.sets_played, 0)                as sets_played,
  coalesce(t.sets_a, 0)                     as sets_a,
  coalesce(t.sets_b, 0)                     as sets_b,
  coalesce(t.points_a, 0)                   as points_a,
  coalesce(t.points_b, 0)                   as points_b,
  case
    when coalesce(t.sets_a, 0) >= (s.scoring_rules->>'gamesToWin')::int then 'a'
    when coalesce(t.sets_b, 0) >= (s.scoring_rules->>'gamesToWin')::int then 'b'
    else ''
  end                                        as winner
from session.games g
join session.sessions s
  on s.community_id = g.community_id and s.id = g.session_id
left join lateral (
  select count(*)::int                                          as sets_played,
         count(*) filter (where x.score_a > x.score_b)::int     as sets_a,
         count(*) filter (where x.score_b > x.score_a)::int     as sets_b,
         sum(x.score_a)::int                                    as points_a,
         sum(x.score_b)::int                                    as points_b
  from session.game_sets x
  where x.community_id = g.community_id
    and x.session_id = g.session_id
    and x.round_no = g.round_no
    and x.court_no = g.court_no
) t on true;
```

Column meanings:

- `sets_a`/`sets_b`: number of sets won, not points.
- `points_a`/`points_b`: total points of all sets; this is what standings use
  as `pointsFor`/`pointsAgainst`.
- `winner`: `'a'`/`'b'` only if the match has reached `gamesToWin`; an empty string
  for a partial match or a game without sets.
- `points_to_win`: the rating target frozen for that session.

Invariant the engine must keep: `winner <> ''` implies
`sets_played >= games_to_win` and `sets_a = games_to_win` or
`sets_b = games_to_win`.

Performance note: the lateral aggregate uses the unique index
`(session_id, round_no, court_no, set_no)`, and all readers filter
`community_id` + `session_id` (or a date window via `rating.events`)
before the join. For the current community size (40 sessions, ~150 players) the cost is
not noticeable; if it becomes necessary later, the view can be turned into a materialized view without
changing readers.

### 6.3 Old columns

`session.games.score_a/score_b`:

- **no longer written** after P0 (including `setScore`, `setPlayed`, `swap`);
- still exist as the backfill source and the rollback path;
- read only by the migration, not at runtime.

`games_not_tied` stays and is safe: the columns are `null` for all new rows,
and the constraint only applies when both are filled.

The drop is planned in a follow-up migration (P4, after one release):
`alter table session.games drop constraint games_not_tied, drop column score_a, drop column score_b;`
It is not done in 0029 so that rollback is still possible before any BO3 session exists.

### 6.4 Old writers that must change too

The only other place that writes scores directly to `session.games` is the
v1 importer (`tools/import/main.nim:486-502`). After P0, the importer must:

1. keep writing the session without `scoring_preset`/`scoring_rules` (the migration default =
   `legacy_v1`, `pointsToWin` 30, the format v1 actually played);
2. write one `game_sets (set_no = 1)` row every time `score_a/score_b`
   is filled, in the same transaction as the game upsert.

If step 2 is missed, the imported session is invisible to the view: standings
and rating would lose data without an error. Add an import test that
counts `game_sets` = number of scored games.

### 6.5 Why `game_sets` does not hang off `session.games.id`

It could, and it would be simpler. But every route and module already identifies
a game by `(round_no, court_no)` (the game key), and `putSchedule` performs an
upsert based on that pair. Using the id would force every score write to
read the id first and add one query. The natural key that is already used
consistently is cheaper, with the composite FK as a safety net.

### 6.6 Size limits

- `maxPoints ≤ 99` because `game_sets_score_range` and `session.games.score_range`
  use 0..99. The maximum total for one match is 3 × 99 = 297, but the realistic cap
  today is 30 → maximum 90.
- `set_no ≤ 9` leaves room for long formats without a new migration.
- No new limit on the number of players.

---

## 7. Scoring rules engine (pure module)

New file: `modules/session/scoring.nim`. No DB, no config loader,
so it can be tested directly and reused by routes, rating, and (conceptually)
client validation.

### 7.1 Types

```nim
import std/[json, options]

type
  Side* = enum
    sdA = "a"
    sdB = "b"

  SetScore* = object
    a*: int
    b*: int

  ScoringMode* = enum
    smPreset = "preset"
    smLegacy = "legacy"

  ScoringRules* = object
    id*: string
    label*: string
    mode*: ScoringMode
    gamesToWin*: int
    pointsToWin*: int
    winBy*: int
    deuceAt*: Option[int]
    maxPoints*: int
    changeEndsAt*: Option[int]

  SetError* = enum
    seOk = "ok"
    seTie = "tie"
    seRange = "range"
    seTooFewPoints = "too_few_points"
    seAboveCap = "above_cap"
    seWinBy = "win_by"
    seTooManySets = "too_many_sets"
    seSetAfterEnd = "set_after_end"

  SetVerdict* = object
    error*: SetError
    setIndex*: int      # 1-based; 0 when the error is about the list
```

### 7.2 Validating a single set

```nim
proc validSet*(rules: ScoringRules, s: SetScore): SetError =
  if s.a < 0 or s.b < 0 or s.a > 99 or s.b > 99:
    return seRange
  if s.a == s.b:
    return seTie
  if rules.mode == smLegacy:
    # v1 had no format rule: any non-tie in range was a valid game.
    return seOk
  let high = max(s.a, s.b)
  let low = min(s.a, s.b)
  if high > rules.maxPoints:
    return seAboveCap
  if high < rules.pointsToWin:
    return seTooFewPoints
  if high == rules.maxPoints:
    # Cap reached: a one-point lead wins, even if winBy is 2.
    return seOk
  let need = if rules.deuceAt.isSome and low >= rules.deuceAt.get:
               rules.winBy
             else:
               1
  if high - low < need: seWinBy else: seOk
```

Truth table (used as a test):

| Preset | Score | Result | Reason |
|---|---|---|---|
| majadu30 | 30–29 | valid | cap 30 |
| majadu30 | 29–28 | rejected | not yet 30 |
| majadu30 | 30–0 | valid | cap |
| classic21 | 21–19 | valid | 21 points, difference 2 |
| classic21 | 21–20 | rejected | deuce 20–20 needs 2 |
| classic21 | 22–20 | valid | deuce satisfied |
| classic21 | 30–29 | valid | cap |
| classic21 | 31–29 | rejected | above cap |
| classic21 | 29–28 | rejected | deuce, difference 1 |
| classic21 | 20–18 | rejected | not yet 21 |
| bwf15 | 15–13 | valid | 15 points |
| bwf15 | 15–14 | rejected | deuce 14–14 needs 2 |
| bwf15 | 16–14 | valid | deuce satisfied |
| bwf15 | 21–20 | valid | cap 21 |
| bwf15 | 20–19 | rejected | deuce, difference 1 |
| legacy_v1 | 21–19 | valid | legacy mode |
| legacy_v1 | 30–5 | valid | legacy mode |
| all | 15–15 | rejected | tie |

Note the rule order: the cap is checked **before** `winBy`. Without that order,
30–29 in classic21 would be rejected because of deuce, even though the cap is exactly
what ends the deuce.

### 7.3 Validating the set list

```nim
proc validateSets*(rules: ScoringRules, sets: openArray[SetScore]): SetVerdict =
  if sets.len > 2 * rules.gamesToWin - 1:
    return SetVerdict(error: seTooManySets)
  var wonA, wonB = 0
  for index, s in sets:
    let single = validSet(rules, s)
    if single != seOk:
      return SetVerdict(error: single, setIndex: index + 1)
    if wonA >= rules.gamesToWin or wonB >= rules.gamesToWin:
      return SetVerdict(error: seSetAfterEnd, setIndex: index + 1)
    if s.a > s.b: inc wonA else: inc wonB
  SetVerdict(error: seOk)
```

`seNotContiguous` is never used: the body always sends the full list, so
no input can produce it. That enum member has been removed so that there is no
dead branch mapped to a response code.

### 7.4 Derivations

```nim
proc setsWon*(rules: ScoringRules, sets: openArray[SetScore]): (int, int)
proc matchComplete*(rules: ScoringRules, sets: openArray[SetScore]): bool
proc winnerSide*(rules: ScoringRules, sets: openArray[SetScore]): Option[Side]
proc points*(sets: openArray[SetScore]): (int, int)
```

`matchComplete` = `setsWon[0] >= gamesToWin or setsWon[1] >= gamesToWin`.

### 7.5 Margin for rating

```nim
proc ratingMargin*(rules: ScoringRules, sets: openArray[SetScore]): float =
  ## Average margin per set, relative to the game's target:
  ##
  ##   r = sum(a - b) / (pointsToWin * setsPlayed)
  ##
  ## The caller feeds `r * pointsToWin` into
  ## gameValue(base, margin, target = pointsToWin), so the result is
  ##   base * (0.5 + 0.5 * clamp(r, -1, 1)).
  ##
  ## For a single set this is exactly the v1 formula with target 30, which is
  ## the format legacy sessions were played in.
  if sets.len == 0 or rules.pointsToWin <= 0:
    return 0.0
  var total = 0
  for s in sets:
    total += s.a - s.b
  total.float / (rules.pointsToWin.float * sets.len.float)
```

There is no separate target field: `pointsToWin` from the snapshot is the rating
target. Old sessions use 30 because they really are MAJADU 30; new sessions use
their preset target. `rating.score_target` only remains as a fallback for
rows without a snapshot (see §10.5).

### 7.6 Serialization

```nim
proc parseRules*(node: JsonNode): ScoringRules
proc rulesJson*(rules: ScoringRules): JsonNode
proc parsePresets*(node: JsonNode): seq[ScoringRules]
```

`parseRules` is used for config and for reading the snapshot from the DB. Both
shapes are identical; there is no default that applies on only one path.

### 7.7 Client-side copy

`apps/web/src/legacy/utils/scoreValidation.ts` currently only checks ties and
0..99. Replace it with a function that takes `scoring` from the session response and
implements the same rules. This is a **preview**, not the authority:
the server still revalidates and returns error codes.

The reason for copying instead of calling the server per set: an operator types three sets
in a row; a round-trip per set makes input feel broken on a slow network.
Client tests must use the same truth table as the Nim engine (see
§16) so the two implementations do not drift.

---

## 8. Write path & read path

### 8.1 Creating a session

`POST /c/{slug}/sessions` accepts the optional `scoringPreset` field.

Order in `createSession` (`apps/api/src/app.nim:~575`):

1. Read `scoringPreset`; if it is not a string → `400 INVALID_BODY`.
2. Fetch the config snapshot + community settings (`currentSettings`).
3. Determine the id: the field → or `stringValue(settings, keySessionDefaultScoringPreset)`.
4. Look up the preset in `session.scoring_presets`; not found → `400 INVALID_PRESET`.
   `legacy_v1` is also rejected here.
5. Build `scoring_rules` from the preset (no separate target field).
6. Insert the session with both columns.

Old sessions never go through this path; their columns are already filled with the migration default.

### 8.2 Changing the preset

`PATCH /c/{slug}/sessions/{id}` accepts `scoringPreset`.

Guard (in `modules/session/write.nim`):

```
if patch.scoringPreset.isSome:
  the session must have status 'draft'    -> 409 LOCKED
  there must be no session.game_sets row  -> 409 PRESET_LOCKED
  the id must exist in the current config -> 400 INVALID_PRESET
  the snapshot is replaced in full (not merged)
```

The snapshot is replaced, not patched, so the session rules are always consistent with
the selected preset.

"No sets yet" means the operator must clear the sets first:
`PATCH .../games/{key}` with `{"sets": []}` deletes all sets and
returns the game status to `scheduled`. There is no new endpoint.

### 8.3 Writing scores

`PATCH /c/{slug}/sessions/{id}/games/{gameKey}` (unchanged, with `If-Match`):

New body:

```json
{
  "sets": [
    {"a": 21, "b": 18},
    {"a": 19, "b": 21},
    {"a": 21, "b": 17}
  ]
}
```

The old body is still accepted:

```json
{"scoreA": 30, "scoreB": 28}
```

Compatibility rules:

| Session preset | `scoreA/scoreB` body | `sets` body |
|---|---|---|
| `gamesToWin = 1` (including legacy) | accepted → one set | accepted, at most 1 set |
| `gamesToWin > 1` | `400 SETS_REQUIRED` | accepted |

`scoreA/scoreB` for a multi-set session is not "guessed" into the first set. Guessing
would create a 1–0 match that was never played.

Write path (`setSets` in `schedule.nim`, replacing `setScore`):

```
1. parseGameKey
2. gate(): draft + version matches                -> 404/409
3. read the session scoring_rules
4. validSet for each set                           -> 400 INVALID_SCORE (index)
5. validateSets (count, order, after end)          -> 400 INVALID_SET_SEQUENCE
6. bump() the session version
7. delete from session.game_sets where ...
8. insert all sets
9. update session.games set status = 'played' | 'scheduled'
   - played when matchComplete
   - scheduled when partial or empty
10. commit
```

Status note: if a match was previously marked `played` without sets, then a partial set
is filled in, the status goes back to `scheduled` until the match is really
finished. `played` means "happened and complete" for counting purposes; the
"happened without a score" marker only applies while no sets exist yet.

All of steps 6–9 are in one transaction, so there is no "sets saved
but status wrong" state if the process dies halfway.

An empty set list (`{"sets": []}`) means delete the score: the sets are deleted, status `scheduled`.
This is also how to cancel a match that was entered incorrectly.

The game status is **not** given an `in_progress` value. The three old values
(`scheduled`/`played`/`cancelled`) are enough; progress is read from the length of `sets`.
Adding a status value would force changes to the constraint, the contract, and every
consumer that compares strings.

### 8.4 `setPlayed`

Old behaviour: `{"played": true}` marks the game as happened without a score;
`{"played": false}` returns it to `scheduled` and deletes the score.

New behaviour:

| Body | Sets present? | Effect |
|---|---|---|
| `{"played": true}` | no | status `played`, no sets (same as v1) |
| `{"played": true}` | yes | `409 MATCH_HAS_SETS`: ask to clear first |
| `{"played": false}` | no | status `scheduled` |
| `{"played": false}` | yes | sets deleted, status `scheduled` |

Why `true` + sets is rejected: marking a match that has sets as "played" would delete
the sets already filled in, and that must not happen from an accidental click. The
purpose of "played without a score" only makes sense before any sets exist.

### 8.5 Swap

`modules/session/swap.nim` moves the content of one game to another game (including
players and scores) while the session is a draft. With sets:

- `readContent` also reads `game_sets` for (round, court);
- `writeContent` moves the sets to the target;
- `score_a/score_b` is still copied as-is (for legacy sessions that still
  store it), even though new rows are always `null`.

Order inside the transaction: read both sides → delete the sets in both slots → write
the sets to the target. The unique `(session_id, round_no, court_no, set_no)` is safe because
the deletion happens before the insert.

Required test: swapping a 2–1 BO3 game into an empty slot keeps the three sets and
the winner; swapping back restores the original state.

### 8.6 Deleting a session

`session.game_sets` uses `on delete cascade` to `session.games`, and
`session.games` cascades to `session.sessions`. `delete` in `write.nim` already
deletes `session.games`; the sets follow with no code change. The existing tests must
still pass.

### 8.7 Reading a session

`GET /c/{slug}/sessions/{id}`:

```json
{
  "id": "...",
  "title": "SUNDAY FUNDAY",
  "date": "2026-11-01",
  "scoring": {
    "preset": "classic21",
    "label": "Classic BO3 21",
    "gamesToWin": 2,
    "pointsToWin": 21,
    "winBy": 2,
    "deuceAt": 20,
    "maxPoints": 30,
    "changeEndsAt": 11
  },
  "games": [
    {
      "round": 1,
      "court": 1,
      "sideA": ["..."],
      "sideB": ["..."],
      "scoreA": 61,
      "scoreB": 58,
      "setsWonA": 2,
      "setsWonB": 1,
      "winner": "A",
      "sets": [
        {"set": 1, "a": 19, "b": 21},
        {"set": 2, "a": 21, "b": 18},
        {"set": 3, "a": 21, "b": 19}
      ],
      "status": "played"
    }
  ]
}
```

Payload rules:

- `scoreA/scoreB` = total points of all sets (not sets won). The names
  are kept so old consumers do not break; the new meaning is documented.
- `setsWonA/setsWonB` = number of sets.
- `winner` = `"A"`, `"B"`, or `null`. For a partial match, `null`.
- `sets` is always present (an empty array for a game without a score).
- `scoring` is only in detail and share, **not** in the create/patch/lock responses,
  so the parity diff is smaller and clients really do always read the detail after
  navigation.

`GET /c/{slug}/sessions/{id}/games/{gameKey}` returns the same game shape
(without `scoring`), for consumers that read a single game.

`GET /s/{code}` uses the same game shape + `scoring` at the top level.

### 8.8 Reading standings

`sessionStandings.compute` still returns the same shape
(`items[].wins/losses/pointsFor/pointsAgainst/diff`). Only the query changes:

```sql
select round_no, court_no, winner, points_a, points_b, status
from session.game_results
where community_id = $1 and session_id = $2
  and status = 'played' and winner <> ''
```

Calculation:

- side A wins when `winner = 'a'`;
- `pointsFor` = `points_a` or `points_b` depending on the side;
- one match adds **one** win/loss.

There is no need to change sorting or the JSON shape.

---

## 9. API & contract

### 9.1 Summary of changes

| Operation | Change | New error codes |
|---|---|---|
| `POST /c/{slug}/sessions` | optional `scoringPreset` field | `400 INVALID_PRESET` |
| `PATCH /c/{slug}/sessions/{id}` | optional `scoringPreset` field, set guard | `409 PRESET_LOCKED`, `400 INVALID_PRESET` |
| `PATCH .../games/{gameKey}` | `sets[]` body; `scoreA/scoreB` only for single-set | `400 SETS_REQUIRED`, `400 INVALID_SET_SEQUENCE`, `409 MATCH_HAS_SETS` |
| `GET .../sessions/{id}` | `scoring`, `sets`, `setsWonA/B`, `winner` | none |
| `GET .../sessions/{id}/games/{gameKey}` | new game shape | none |
| `GET /s/{code}` | `scoring` + new game shape | none |
| `GET .../standings` | unchanged | none |
| `GET /c/{slug}/config` | read-only `scoringPresets` field | none |
| `PATCH /c/{slug}/settings` | validation of `session.default_scoring_preset` | `400 INVALID_CONFIG` |

The old `400 INVALID_SCORE` is still used; its message names the set number
(`set 2: win by 2`).

### 9.2 OpenAPI contract

`packages/contracts/openapi/core.yaml` and `community.yaml` do not
define body schemas. So:

- there is no change to `operationId`, paths, or the number of operations (still 75);
- changes are only in the request/response descriptions;
- `packages/web-client/src/api.ts` and `apps/api/src/routes_gen.nim` **do not
  change**, proven by the `CONTRACT.sha256` fingerprint.

What is documented:

1. `createSession`: the `scoringPreset` field, default from
   `session.default_scoring_preset`, id list from `session.scoring_presets`.
2. `patchSession`: the same field + the "no sets recorded yet" condition.
3. `patchGame`: the two body shapes, the error codes, and the meaning of `scoreA/scoreB` as
   total points.
4. `getSession` / `getGame` / `getShared`: new fields.
5. All of them still mention `429`, `413`, `If-Match`, `ETag` as they do now.
6. `getCommunityConfig`: the `scoringPresets` field; `patchSettings`: validation of the
   default preset id.

Regeneration: `./task contract-gen && ./task contract-check`.

### 9.3 Parity

The `testdata/parity/v2` corpus contains 34 session-related cases. Those whose bodies change:

- `get_session*`, `get_shared*`, `get_game*` (new fields);
- `create_session`, `patch_session*`, `lock_session*` **do not** change because
  `scoring` is not added to the write responses.

Plan: re-record the detail/share/game cases after P0, and re-record the
rating/board cases because the target changes 21 → 30 (§11.A). The `v1` golden corpus
cases must still pass; only this repo's v2 corpus changes. Record with the
commands in `task.d/parity*.sh`; do not edit the JSON by hand.

---

## 10. Impact on point calculation (rating)

### 10.1 The formula in effect

One match contributes one value:

```
r      = Σ(a_s − b_s) / (pointsToWin × setsPlayed)     # average margin per set
v      = sessionBase × (0.5 + 0.5 × clamp(r, −1, 1))
points = v × opponentMultiplier
```

Then one session entry = the sum of all match values, and the board takes the
`best_n` entries within `window_weeks`.

What does **not** change:

- `sessionBase` (250), `opponent_clamp` (0.5..1.5), `window_weeks` (12),
  `best_n` (10), `thin_evidence_n` (3), `tier_bands`.
- `opponentMultiplier` is computed per match from the opponent tier, not per set.
- Number of entries: one session is still one entry, however many sets or matches it has.
- `player_state`: one match adds one `games_played` and one win/loss.

### 10.2 Key property: antisymmetry

`v(+r) + v(−r) = sessionBase` as long as the clamp is not hit. That means the points
given to the winner and to the opponent always add up to 250 (before the multiplier).
This is already correct today and stays correct after the change.

What changes is the **distribution**:

- Previously, target 21 on a 30-point game made a margin of 25 (30–5) hit the clamp →
  winner 250, opponent 0.
- Now target 30 makes a margin of 25 become `r = 0.833` → 229.17 and 20.83.

So a blowout no longer gives the full reward. Because points are recomputed when
read, this fix applies to old sessions as well.

### 10.3 One scale, three formats

| Data | Target | Example 30–28 | Example 30–5 |
|---|---|---|---|
| Old sessions (MAJADU 30) | 30 | 133.33 | 229.17 |
| New MAJADU 30 sessions | 30 | 133.33 | 229.17 |
| New Classic 21 sessions | 21 | n/a (score 21) | n/a |
| New BWF 15 sessions | 15 | n/a (score 15) | n/a |

Consequences that must be understood:

- **The old board moves.** Players whose points came largely from blowouts
  lose some; players who lost narrowly gain more.
- The total points of one match remain 250, so the community total does not inflate or
  shrink; only its distribution changes.
- Stored daily snapshots (`rating.snapshots`) still contain the old numbers.
  `prevRank`/`rankDelta` may show movement once at release. Existing `rank_streak`
  badges are **not** recomputed (see §17).
- There is no point migration: `rating.events` does not store points, so it is enough to
  deploy and the board immediately uses the new target.

### 10.4 Why the average per set, not the total

With the raw point total:

- BO3 is automatically worth up to 3× one game (42–63 points vs 30);
- a 2–0 winner always beats a 2–1 winner only because they played fewer
  sets;
- cap and deuce have no meaning in points.

With the average per set:

- 2–0 and 2–1 winners with the same dominance are worth the same;
- dragging a match to three sets does not add points;
- a long deuce win (30–29, 30–29) is actually worth less than a
  normal win (21–15, 21–15), because the ratio measures dominance, not
  endurance. This is behaviour that already exists in v1 for a single game.

### 10.5 Effect on point readers

| Reader | Change |
|---|---|
| `projection.sessionEntries` | JOIN to `session.game_results`; `target = points_to_win` per row; `margin = ratingMargin × target` |
| `read.boardRows` | unchanged (uses the projection) |
| `read.playerHistory` | use `points_a/points_b` and add `sets` |
| `read` most frequent opponents/partners | use the view, count per match |
| `ingest` | win/loss from `winner`; does not count points |
| `achievement` | `games`/`wins` per match |
| `snapshots` | unchanged; `rating` = the board points of that day |

The projection implementation does not need to read `game_sets` one by one: the view already
gives `points_a`, `points_b`, and `sets_played`, and `Σ(a−b) = points_a −
points_b`. So this is enough:

```
r = (points_a - points_b) / (points_to_win * max(sets_played, 1))
value = gameValue(base, r * points_to_win, points_to_win)
```

`ratingMargin` in the engine is still used for unit tests and the UI preview, with
the same result.

`rating.score_target` stays in the registry as a **fallback** if a
row has no `scoring_rules` (not possible after the migration, but
it avoids a `null` that would drop a session from the board). The query uses:

```sql
coalesce((s.scoring_rules->>'pointsToWin')::int, $4::int) as target
```

with `$4 = rating.score_target` (the migration raises it to 30). After two
releases this key can be removed; no session is rated with 21 anymore except
the Classic 21 preset.
A community override on `rating.score_target` no longer affects sessions:
its value is only used if the snapshot is genuinely missing.

### 10.6 Tournaments are not affected

`tournamentEntries` already uses a per-phase target (`classicTarget`,
`teamTarget` in `modules/rating/infrastructure/tournament.nim`). There is no
change there. Tournaments remain out of scope for the feature.

---

## 11. Number simulations

All examples use `sessionBase = 250`, `opponentMultiplier = 1.0` unless
stated otherwise. Rounding to an integer only happens when the entry total is reported.

### 11.A Old sessions: before vs after

An old session (`legacy_v1` snapshot), three games. Previously rated with target 21;
now target 30:

| Game | Score | r (21) | Value (21) | r (30) | Value (30) |
|---|---|---|---|---|---|
| 1 | 30–28 | 0.095238 | 136.90 | 0.066667 | 133.33 |
| 2 | 30–25 | 0.238095 | 154.76 | 0.166667 | 145.83 |
| 3 | 28–30 | −0.095238 | 113.10 | −0.066667 | 116.67 |
| **Total** | | | **404.76** | | **395.83** |

Change: −8.93 points (−2.2%) for this player. Their opponents gain
the same amount, because every match still adds up to 250.

Per-match example:

- 30–28: winner 136.90 → 133.33 (−3.57), opponent 113.10 → 116.67 (+3.57);
- 30–5: winner 250.00 → 229.17 (−20.83), opponent 0.00 → 20.83 (+20.83).

So the board moves from players who win big to players who lose narrowly.
There is no data migration; the change happens when the board is read.

### 11.B New MAJADU 30 sessions

New sessions use the `majadu30` snapshot with `pointsToWin = 30`, so the numbers
are exactly the same as the "30" column in §11.A. There is no second era: old and new
sessions for the same format are now rated on the same scale.

### 11.C Blowout

| Score | Before (target 21) | After (target 30) |
|---|---|---|
| 30–5 (winner) | 250.00 (clamp) | 229.17 |
| 5–30 (opponent) | 0.00 (clamp) | 20.83 |
| Sum | 250.00 | 250.00 |

The reward for winning big drops by 20.83 points, and the opponent no longer gets zero.
A player whose sessions are all blowouts loses about 8% of their points; their opponents
gain an equivalent amount. This applies to old and new sessions.

### 11.D BO3 normalization

Classic BO3 21:

| Sets | Σ margin | S | r | Value |
|---|---|---|---|---|
| 21–19, 21–19 | 4 | 2 | 0.095238 | 136.90 |
| 21–19, 19–21, 21–19 | 2 | 3 | 0.031746 | 128.97 |
| 21–18, 21–18 | 6 | 2 | 0.142857 | 142.86 |
| 21–18, 18–21, 21–18 | 3 | 3 | 0.047619 | 130.95 |
| 21–15, 21–15 | 12 | 2 | 0.285714 | 160.71 |
| 30–29, 30–29 | 2 | 2 | 0.047619 | 130.95 |
| 21–0, 21–0 | 42 | 2 | 1.000000 | 250.00 |

BWF 15:

| Sets | Σ margin | S | r | Value |
|---|---|---|---|---|
| 15–13, 15–13 | 4 | 2 | 0.133333 | 141.67 |
| 15–10, 15–10 | 10 | 2 | 0.333333 | 166.67 |
| 21–19, 21–19 (cap) | 4 | 2 | 0.133333 | 141.67 |
| 15–0, 15–0 | 30 | 2 | 1.000000 | 250.00 |

Two things to be aware of:

1. **Winning 2–0 is not twice winning 1–0.** 21–18, 21–18 (142.86) equals
   a single set of 21–18 (r = 3/21 = 0.142857). That really is the point: the format
   gives no bonus just because there is a second set.
2. **A long deuce win is worth less.** 30–29, 30–29 (130.95) is below
   21–19, 21–19 (136.90), because the ratio measures dominance. This is consistent
   with the v1 formula and needs to be communicated if anyone asks.

### 11.E Comparison between presets at equivalent dominance

| Preset | Score | r | Value |
|---|---|---|---|
| MAJADU 30 | 30–21 (margin 9 = 30% of target) | 0.30 | 162.50 |
| Classic 21 | 21–15, 21–15 (margin 6 = 28.6%) | 0.285714 | 160.71 |
| BWF 15 | 15–11, 15–11 (margin 4 = 26.7%) | 0.266667 | 158.33 |

The difference between presets is under 5 points for comparable dominance. This is evidence
that normalization works: choosing a format does not become a cheat to raise
points.

### 11.F Simulation of one full session

Session `classic21`, 4 players, 3 matches, one court:

| Match | Sides | Set score | Sets | Points |
|---|---|---|---|---|
| 1 | A+B vs C+D | 21–18, 21–19 | 2–0 | 42–37 |
| 2 | A+C vs B+D | 19–21, 21–18, 21–19 | 2–1 | 61–58 |
| 3 | A+D vs B+C | 21–15, 21–17 | 2–0 | 42–32 |

Match values:

| Match | Σ margin | S | r | Win | Loss |
|---|---|---|---|---|---|
| 1 | 5 | 2 | 0.119048 | 139.88 | 110.12 |
| 2 | 3 | 3 | 0.047619 | 130.95 | 119.05 |
| 3 | 10 | 2 | 0.238095 | 154.76 | 95.24 |

Session entry per player (one entry, summed):

| Player | Match | Value | Entry total |
|---|---|---|---|
| A | M1 W, M2 W, M3 W | 139.88 + 130.95 + 154.76 | **425.59 → 426** |
| B | M1 W, M2 L, M3 L | 139.88 + 119.05 + 95.24 | **354.17 → 354** |
| C | M1 L, M2 W, M3 L | 110.12 + 130.95 + 95.24 | **336.31 → 336** |
| D | M1 L, M2 L, M3 W | 110.12 + 119.05 + 154.76 | **383.93 → 384** |

Standings for the same session (one match = one win/loss):

| Rank | Player | W–L | PF | PA | Diff |
|---|---|---|---|---|---|
| 1 | A | 3–0 | 145 | 127 | +18 |
| 2 | D | 1–2 | 137 | 135 | +2 |
| 3 | B | 1–2 | 132 | 140 | −8 |
| 4 | C | 1–2 | 130 | 142 | −12 |

Note that D is above B and C even though all are 1–2: diff tie-break. This stays
consistent with the old rules.

### 11.G Partial sets are not counted

If match 2 has only two sets filled in (19–21, 21–18), then:

- `winner = ''`, `sets_played = 2`;
- match 2 is not counted in standings and not counted in rating;
- A's temporary entry = 139.88 + 154.76 = 294.64 (two matches), then becomes 425.59
  after the third set is filled in.

There are no "temporary points" that need to be rolled back. Once the match is finished,
the next `ingest`/projection uses the final numbers.

### 11.H Opponent multiplier

If the average opponent tier strength is 1.2× the population:

- match 1 for A/B: 139.88 × 1.2 = 167.86;
- match 1 for C/D: 110.12 × 1.2 = 132.14.

The sum is still 300 (250 × 1.2). The format change does not touch the multiplier.

### 11.I best-N and window

A player with 12 sessions in 12 weeks: the best 10 entries are still counted. A
BO3 session is still **one** entry even though it contains three matches. So switching
format does not increase or decrease the number of entries competing on the board; only the value
per entry changes.

### 11.J Achievement

| Metric | Change |
|---|---|
| `games:*` | one BO3 match = 1 game (not 3) |
| `wins:*` | one BO3 match = 1 win |
| `sessions:*` | unchanged |
| `rank:*`, `rank_streak:*` | unchanged (snapshot) |
| `partners/opponents` | counted per match, not per set |

Example: a player with 12 Classic 21 matches gets the `games:10` badge at match
10, the same as with 12 MAJADU 30 matches.

---

## 12. Standings

### 12.1 Minimal change

`modules/session/standings.nim` only replaces the game query and the source of
wins/losses:

```nim
for game in db.query("""
  select round_no, court_no, winner, points_a, points_b
  from session.game_results
  where community_id = $1::uuid and session_id = $2::uuid
    and status = 'played' and winner <> ''
  order by round_no, court_no""", ...):
  ...
  let aWon = game.get("winner") == "a"
```

Absence and skip rules stay:

- a side whose players are all absent → the match is dropped;
- a skipped player is not counted, the other side still gets the result;
- if both sides are empty after the skips → the match is dropped.

Only one line changes: `scoreA > scoreB` becomes `winner = 'a'`, and
`pointsFor/Against` use the match point total.

### 12.2 Tie-break

Unchanged: wins → diff → pointsFor → name. No change.

Note: `diff` within one BO3 session uses the total points of 3 sets (for example +18), so
the number is larger than in a single game session. That is not a problem because
standings are always per session and never combine two formats.

If cross-session "season standings" ever exist, they must use rating
points, not raw `pointsFor`. That is already the design direction now.

### 12.3 Display

`GET .../standings` **does not change shape**, so parity is safe. Set details are not
put into standings because a standings row is one player, not
one match. Set details live in `games` in the session detail/share.

In the UI, the Standings tab stays as it is now. The only addition is a small "set" column
in the match card (not in the standings table), for example `2–1` with the details
below it.

### 12.4 Absence & skip in a BO3 match

Example: A+B vs C+D, score 2–1, but B is recorded as skipped in that match.

- A still gets the win and side A's total points;
- B gets nothing;
- C and D get the loss and side B's total points.

This is the same as the current single-game behaviour. There is no new per-set rule,
because a skip always applies to the whole match.

---

## 13. Achievement, share, export

### 13.1 Achievement

`modules/achievement/infrastructure/backfill.nim` replaces the game query with the
view and uses `winner`:

```nim
let aWon = row.get("winner") == "a"
```

There is no change to the badge catalogue or thresholds. What needs to be tested:

- 10 BO3 matches → `games:10`, not `games:25`;
- winning 2–0 and 2–1 are both one win;
- a rebuild after changing sets recounts correctly.

### 13.2 Share (`GET /s/{code}`)

Addition:

```json
{
  "session": {"id": "...", "title": "...", "date": "...", "status": "..."},
  "scoring": {
    "preset": "classic21",
    "label": "Classic BO3 21",
    "gamesToWin": 2,
    "pointsToWin": 21,
    "winBy": 2,
    "deuceAt": 20,
    "maxPoints": 30
  },
  "games": [
    {
      "round": 1, "court": 1,
      "sideA": ["A", "B"], "sideB": ["C", "D"],
      "scoreA": 61, "scoreB": 58,
      "setsWonA": 2, "setsWonB": 1,
      "winner": "A",
      "sets": [
        {"set": 1, "a": 19, "b": 21},
        {"set": 2, "a": 21, "b": 18},
        {"set": 3, "a": 21, "b": 19}
      ],
      "status": "played"
    }
  ],
  "standings": {"items": [...]}
}
```

`standings` still come from the server (`sessionStandings.compute`), so the public page
and the member page cannot differ.

### 13.3 Instagram export

`InstagramPostPage` uses `computeStandings` on the client from `CloudSnapshot`.
After the change:

- `computeStandings` takes `setsWonA/setsWonB` (or `winner`) and the total
  points; if the new fields are missing (old data in the cache), fall back to
  `scoreA/scoreB`;
- `canvasPost.ts`, which determines the winner from comparing scores
  (`row.scoreA > row.scoreB`), must use `winner`/`setsWon`, otherwise the
  result card could mark the wrong winner in a 2–1 match;
- the top-10 table does not change;
- the result card shows `2–1` large and `21–18, 19–21, 21–17` small;
- for `gamesToWin = 1`, the display stays `30–28` so there is no noise.

The 1080×1350 canvas limit is enough: one set-detail line uses an 11–12
px font and at most ~90 characters. If it is longer (for example 30–29, 29–30, 30–29),
it still fits; there is no need to change the canvas size.

`PREVIEW`/story uses `STORY_WIDTH/STORY_HEIGHT` from
`legacy/config/canvas.ts` (already consolidated in `d16a3ad`); there are no new numbers.

### 13.4 Scoreboard

`ScoreboardPage` reads the same session. If it displays the score, use
`setsWonA/setsWonB` + `sets`; there is no new endpoint.

---

## 14. UI

### 14.1 Wizard (`apps/web/src/legacy/pages/SetupPage.tsx`)

A new "Score format" card in step 1, above Courts:

```
Score format
( ) MAJADU 30        Single game · 30 points · no deuce
(•) Classic BO3 21   Best of 3 · 21 points · deuce 20–20 · cap 30
( ) New BWF BO3 15   Best of 3 · 15 points · deuce 14–14 · cap 21
```

Behaviour:

- Default = `session.default_scoring_preset` from the `effective` config already
  read by the page (community scope); the option list comes from the `scoringPresets` field
  on the same config response.
- The choice is kept in wizard state and sent as `scoringPreset` on
  create.
- The rule summary is one line of text, not a table; operators do not need to
  read a matrix.
- No extra step. The wizard stays at 4 steps.
- If the preset config changes while the wizard is open, the selected id can disappear;
  create will answer `400 INVALID_PRESET` and the UI shows the message "format
  is no longer available, choose again" and reloads the list.
- Accessibility: `fieldset`/`legend`, real radios (not divs), connected labels,
  touch targets ≥ 44 px, visible focus.

### 14.2 Score editor (`ScheduleGrid` + `useScoreDraft`)

The state changes from `{a: string, b: string}` to:

```ts
type SetDraft = { a: string; b: string }
type MatchDraft = { sets: SetDraft[] }
```

Flow:

1. Click `+ score` → the panel opens with one row per set.
2. A set row is added automatically when the previous set is valid and the match is not finished.
3. The set that decides the winner closes the next input.
4. The save button sends the **whole** set list (not one set).
5. An empty set in the middle is rejected with the message "set 2 is empty" (it is not sent
   as 0–0).
6. `Clear` sends `{"sets": []}`.

Client validation uses `scoring` from the session; the server remains authoritative.

Server error messages are mapped:

| Code | UI message |
|---|---|
| `INVALID_SCORE` | "Set 2: win by 2 at 20–20" |
| `INVALID_SET_SEQUENCE` | "No more sets: the match is already won" |
| `SETS_REQUIRED` | "This format needs set scores" |
| `MATCH_HAS_SETS` | "Clear the sets before marking the match played" |
| `PRESET_LOCKED` | "Preset is locked once a set is recorded" |

### 14.3 Compact display

`SlotGameCard` / `ScheduleGrid`:

- finished match: `2–1` large, `21–18 · 19–21 · 21–17` small;
- partial match: `1–1` with `in progress` (not colour alone);
- single game: still `30–28`;
- do not show total points as the main number, total points can
  mislead (lost on total points but won the match).

`PlayerMatchDetailSheet` adds a set-detail line below the match score.

### 14.4 Community settings (`apps/web/src/pages/SettingsPage.tsx`)

`FIELDS` currently only supports `text`/`number`. Add `select`:

```ts
{ key: 'session.default_scoring_preset', label: 'community.setting.scoringPreset',
  kind: 'select', optionsFrom: 'scoringPresets' }
```

Options come from `scoringPresets` on the `GET /c/{slug}/config` response
(not from `effective`), labels from the preset `label`.
Saving uses the existing `updateCommunityConfig`; the server validates the id.

Add i18n strings in `apps/web/src/i18n/en.ts`:

```
'community.setting.scoringPreset'
'setup.scoring.title'
'setup.scoring.hint'
'score.set'
'score.setsRequired'
'score.matchWon'
'score.clear'
```

### 14.5 Copywriting

- "Score format", not "Scoring preset", in the UI.
- The summary uses players' terms: "Best of 3", "deuce 20–20", "cap 30".
- Avoid "game" for a set; in the UI, "game" = a match played.
- No technical terms such as `ratingTarget` on screen.

### 14.6 Loading & error state

- Wizard: the preset list comes from the config already loaded by the page; there is no
  extra spinner.
- Editor: the save button is disabled during the request; errors appear in the panel and do not
  close the panel.
- Share: if `scoring` is missing (old cache), show the score only without
  set details; do not guess the format.

---

## 15. Work phases & acceptance criteria

### P0: config, schema, engine, readers (1–2 days)

Contents:

1. Registry + seed + migration `0029_scoring_presets.sql`.
2. `modules/session/scoring.nim` + unit tests for the truth table.
3. Backfill sets from the old scores.
4. View `session.game_results`.
5. Move **all** readers to the view: standings, projection, ingest, read,
   achievement.
6. Session/share detail returns `sets`, `setsWonA/B`, `winner`, `scoring`.
7. `POST /sessions` accepts `scoringPreset` and stores the snapshot
   (`legacy_v1` for old data, the preset for new sessions).
8. `PATCH` score still accepts `scoreA/scoreB` (single-set) so the old UI
   keeps working; underneath, `setScore` writes one `game_sets` row
   (not `score_a/score_b`), so the view is already the only
   source of truth from P0 on.
9. `GET /c/{slug}/config` returns the read-only `scoringPresets`.
10. The v1 importer also writes `game_sets` for old scores (§6.4).

Acceptance criteria:

- `./task check`, `./task verify session|rating|achievement|api` pass.
- `./task parity v1 verify` does not change.
- The board change follows §11.A: old numbers are recomputed with target 30;
  the total per match stays 250, no points are lost.
- Old daily snapshots are not rewritten; `prevRank`/`rankDelta` may
  show movement once at deploy (documented in §17).
- After deploy, run `./task ranksnapshot` so that day's snapshot row
  uses the new numbers (upsert per date, so it is safe to repeat).
- Parity detail/share/game cases are re-recorded; the diff is only the new fields.
- The config case is re-recorded because of `scoringPresets`; there are no new operations.

Note: P0 deliberately does not yet accept `sets` from the client. If there is a bug in the view,
the old UI can still write a single score and no new data is corrupted.

### P1: multi-set write path (1 day)

Contents:

1. `setSets` replaces `setScore` (the old name is kept as a wrapper).
2. `sets[]` body, engine validation, `SETS_REQUIRED`, `INVALID_SET_SEQUENCE`.
3. `{"sets": []}` to delete.
4. `setPlayed` + `MATCH_HAS_SETS`.
5. `PATCH /sessions/{id}` accepts `scoringPreset` + the `PRESET_LOCKED` guard.
6. Swap moves sets.
7. Contract updated + regen.

Acceptance criteria:

- Integration test: write 2 partial sets → not counted; the third set →
  `played`, standings/rating change.
- The preset cannot be changed once a set exists; after clearing it can.
- Swapping a BO3 keeps the sets.
- No path still writes `session.games.score_a/score_b`.

### P2: UI (1–2 days)

Contents:

1. Format card in the wizard.
2. Set editor + client validation.
3. Compact display + player detail.
4. Share page + export.
5. i18n.

Acceptance criteria:

- E2E: create a Classic 21 session, fill three matches, check standings and share.
- MAJADU 30 sessions do not change appearance (visual regression).
- Keyboard-only can fill all sets; errors are read by the screen reader.
- No layout shift in the 1080×1350 card.

### P3: community default + documentation (½ day)

Contents:

1. `select` in Settings.
2. Config route validation.
3. Handbook: data model, config, score flow.
4. `docs/decisions.md` ADR entry.

Acceptance criteria:

- Change the community default → the wizard opens with that choice.
- Override to a non-existent id → `400 INVALID_CONFIG`.
- The documentation explains the retroactive change to target 30 and the reason for
  per-session snapshots.

### P4: cleanup (next release, not now)

1. Drop `session.games.score_a/score_b` + `games_not_tied`.
2. Remove `rating.score_target` once the fallback is no longer needed.
3. Remove the `setScore` wrapper if there are no callers.

Do not do this together with P0–P2: rollback needs the old columns.

### 15.1 Implementation status (6 Nov 2026)

Already done in the working tree, not yet committed:

- P0: registry + seed + migration `0029`, engine `modules/session/scoring.nim`
  (+ unit tests), set backfill, view `session.game_results`, all readers
  moved to the view, detail/game/share return `sets`/`setsWonA/B`/
  `winner`/`scoring`, `POST /sessions` accepts `scoringPreset`, config
  returns `scoringPresets`, the importer writes `game_sets`.
- P1: `setSets`, `sets[]` body, `SETS_REQUIRED`, `INVALID_SET_SEQUENCE`,
  `MATCH_HAS_SETS`, `PRESET_LOCKED`, swap moves sets, `setPlayed`/`skip`
  clear the sets, no writer of `score_a/score_b` remains other than null.
- P2: format card in setup, set editor with client validation, compact `2–1`
  display + set details, player detail, public share page, standings using
  sets. Instagram export also uses the per-set winner.
- P3 (server side + Settings): default preset validation in the config route, the
  default choice in `SettingsPage`.

Verified: `./task check`, `./task verify session`, `./task verify rating`,
`./task verify achievement`, `./task verify api`, `./task parity v2 verify`,
`pnpm check:types`, `pnpm test` (103 tests). Could not be run in this
environment: VPS/Podman deploy evidence, the Linux visual baseline, and the full browser
E2E (the dev server is run by the owner). `pnpm check:tailwind` fails because of two old
arbitrary classes in `ShareLinkPanel.tsx`/`AdminSessionsPage.tsx`, not from
this change.

---

## 16. Test plan

### 16.1 Unit: `modules/session/tests/scoring_test.nim`

- Truth table §7.2 for the three presets + legacy.
- `validateSets`: 0 sets, 1 set, 2 sets, 3 sets, 4 sets on BO3.
- A set after the match is finished → `seSetAfterEnd`.
- `setsWon`, `matchComplete`, `winnerSide` for 2–0, 2–1, 1–2, 1–1.
- `ratingMargin`: single set = margin/target; BO3 = average; legacy uses
  target 30.
- `parsePresets`: duplicate ids, `maxPoints` ≤ `pointsToWin`, `deuceAt` out of
  range, `legacy_v1` rejected.
- `parseSnapshotNode`: `pointsToWin` is required and > 0.
- Config: `rating.score_target` reads 30, `session.default_scoring_preset`
  points to an existing preset.

### 16.2 Integration: sessions

- Partial `sets` are saved, status `scheduled`.
- The third set finishes the match → `played`.
- A fourth set after 2–1 is rejected.
- `scoreA/scoreB` on a BO3 session → `SETS_REQUIRED`.
- `scoreA/scoreB` on a MAJADU 30 session → one set, old behaviour.
- Two concurrent writers → the second gets `409` stale.
- After lock → all writes `409` locked.
- `{"sets": []}` deletes the sets and reopens the preset.
- `{"played": true}` on a match with sets → `MATCH_HAS_SETS`.
- Swap moves sets; deleting a session deletes the sets.

### 16.3 Integration: rating & achievement

- Old session: the entry uses target 30 (golden number §11.A), not 21.
- New MAJADU 30 session: 30–28 → 133.33 before the multiplier.
- Classic 21 session: 21–19, 21–19 → 136.90.
- A partial match does not add an entry.
- One BO3 match adds 1 game/1 win in `player_state`.
- `games:10` is reached at match 10, not set 10.
- Rebuild is idempotent.
- v1 importer: the number of `game_sets` = the number of scored games; imported sessions
  use `legacy_v1` and are rated with target 30.

### 16.4 Parity

- Re-record the `get_session*`, `get_game*`, `get_shared*` cases and config
  (`scoringPresets`).
- Make sure the `create_session`, `patch_session*`, `lock_session*` cases **do not**
  change (because `scoring` is not in the write responses).
- Re-record the rating/board cases for old data, because the target changes 21 → 30
  (compare with the golden numbers in §11.A).
- `./task parity v1 verify` still passes.

### 16.5 E2E

- Wizard: choose Classic 21 → the session is created with that format.
- Fill 3 sets, see `2–1` and the details.
- Standings tab: the winner follows the sets, not the total points.
- Share page: format + set details appear.
- Export: the Instagram card contains the set details and does not overflow.
- MAJADU 30: the old flow stays a single input.

### 16.6 Manual checklist

- [ ] An old session can be opened, unlocked, old scores shown.
- [ ] Changing the preset of an empty session succeeds.
- [ ] Changing the preset of a session with sets is rejected with a clear message.
- [ ] Clear the sets, then change the preset, succeeds.
- [ ] A BO3 session share link opens in a private window.
- [ ] Keyboard-only fills 3 sets.
- [ ] 360 px screen: no input is cut off.

---

## 17. Risks, rollback, and deferred items

### 17.1 Risks

| Risk | Impact | Mitigation |
|---|---|---|
| A reader is missed and still reads `score_a` | BO3 not counted / wrong winner | Reader list in §3 + grep `score_a` in all modules; integration test per reader |
| Parity changes unintentionally | Silent regression | P0 separates new fields from old numbers; the board is tested with the golden numbers in §11.A |
| The board moves at release | Questions like "why did my points drop" | Documentation §10–11 + announcement before deploy; the total per match does not change |
| Old snapshots vs new board | `prevRank`/`rankDelta` move once; `rank_streak` out of sync | Leave historical snapshots; note it in the release. Snapshot rebuild = a separate tool (§19) |
| A bad config makes the process fail to start | API down | Validation at load, seed + migration tested on an empty DB and an old DB |
| Swap loses sets | Data loss | BO3 swap test; single transaction |
| Regenerating the schedule overwrites players while the sets remain | Sets attached to new players | `putSchedule` does not touch sets (same as old scores); the UI warns when a match has sets; an integration test ensures sets are not lost silently |
| The UI allows a fourth set | Repeated server errors | Client validation + the add-set button disabled |
| A preset is deleted while draft sessions exist | Create/patch fails | An `INVALID_PRESET` message telling the user to choose again; old session snapshots are safe |
| `changeEndsAt` is mistaken for a rule | Operator confusion | Label "change-ends hint", it does not block input |

### 17.2 Rollback

- **Before any BO3 session**: revert the code + leave migration 0029 (additive). The old UI
  writes `score_a/score_b` as usual; the view and `game_sets` are unused.
  Old session data stays intact.
- **After a BO3 session exists**: rolling back the code would lose the BO3 scores (they exist only
  in `game_sets`). Do not roll back; do a forward-fix. This is the same as the
  policy for other destructive migrations in the repo.
- Down SQL 0029 (only for environments without BO3 data):

```sql
drop view session.game_results;
drop table session.game_sets;
alter table session.games drop constraint games_identity_unique;
alter table session.sessions
  drop column scoring_rules,
  drop column scoring_preset;
```

### 17.3 Deferred

- Tournaments (format, points, bracket).
- Custom presets through the admin UI.
- Set display on the community ranking page.
- Per-set statistics (for example "tightest set").
- Formats other than best-of-3 (for example best-of-5): the engine already supports
  `gamesToWin` 1..5, the UI does not.
- Removal of `rating.score_target` and the old score columns (P4).

---

## 18. List of files touched

### Backend

| File | Change |
|---|---|
| `modules/platform/config/registry.nim` | 2 new keys + validation |
| `db/seeds/platform_config.sql` | 2 seed rows |
| `db/migrations/0029_scoring_presets.sql` | schema + backfill + view |
| `modules/session/scoring.nim` | **new**: pure engine |
| `modules/session/tests/scoring_test.nim` | **new** |
| `modules/session/schedule.nim` | `setSets`, `setPlayed`, guards |
| `modules/session/write.nim` | `scoringPreset` in patch + node |
| `modules/session/standings.nim` | view |
| `modules/session/swap.nim` | move sets |
| `modules/session/tests/integration/*` | new tests |
| `modules/rating/projection.nim` | view + `points_to_win` |
| `modules/rating/infrastructure/ingest.nim` | view |
| `modules/rating/read.nim` | history & opponents/partners |
| `modules/achievement/infrastructure/backfill.nim` | view |
| `apps/api/src/app.nim` | create, patch, score, detail, share |
| `apps/api/src/config_routes.nim` | default preset validation + `scoringPresets` |
| `tools/import/main.nim` | write `game_sets` when importing scores |
| `packages/contracts/openapi/core.yaml` | session/game/share descriptions |
| `packages/contracts/openapi/community.yaml` | config + settings descriptions |
| `packages/contracts/openapi/api.yaml` | regen output |
| `packages/contracts/openapi/CONTRACT.sha256` | regen output |

### Frontend

| File | Change |
|---|---|
| `apps/web/src/legacy/pages/SetupPage.tsx` | format card |
| `apps/web/src/legacy/components/summary/useScoreDraft.ts` | per-set draft |
| `apps/web/src/legacy/components/summary/ScheduleGrid.tsx` | set panel |
| `apps/web/src/legacy/components/summary/SlotGameCard.tsx` | compact display |
| `apps/web/src/legacy/components/summary/PlayerMatchDetailSheet.tsx` | set details |
| `apps/web/src/legacy/store/scheduleSlice.ts` | score actions |
| `apps/web/src/legacy/utils/scoreValidation.ts` | preset rules |
| `apps/web/src/legacy/utils/sessionSnapshot.ts` | optimistic update |
| `apps/web/src/legacy/utils/standings.ts` | set-aware |
| `apps/web/src/legacy/queries/sessions.ts` | types & payload |
| `apps/web/src/legacy/queries/endpoints.ts` | `sets` body |
| `apps/web/src/legacy/pages/InstagramPostPage.tsx` | set details |
| `apps/web/src/legacy/utils/canvasPost.ts` | winner from `winner`, not the score |
| `apps/web/src/legacy/components/SummaryModal.tsx` | pass the set data through |
| `apps/web/src/community/api.ts` | send `scoringPresets` |
| `apps/web/src/community/useCommunityConfig.ts` | expose the preset list |
| `apps/web/src/pages/SettingsPage.tsx` | default select |
| `apps/web/src/i18n/en.ts` | new strings |

### Documentation

| File | Change |
|---|---|
| `docs/handbook/data-model.md` | new table, view, config |
| `docs/handbook/current-status.md` | migration/key counts |
| `docs/decisions.md` | scoring format ADR |
| `docs/handbook/scoring-presets.md` | this document |

---

## 19. Open questions

Nothing is blocking P0. What is still open and can be answered later:

1. **Historical snapshots.** The board is recomputed with target 30, but the old
   `rating.snapshots` still contain the numbers from 21. Proposal: leave them (the
   `rank_streak` badge does not change, `prevRank` only moves once). If the owner
   wants snapshot history recomputed too, that is a separate tool that replays
   the dates; not included yet.
2. **Format label in the session list.** Showing a "BO3 21" chip in
   `SessionListPage` would change the `GET /sessions` response (parity). Deferred
   until there is a real need.
3. **A fourth preset.** Adding a format = changing `session.scoring_presets`
   only, with no release. The UI shows it automatically because it reads the config.
4. **Tournaments.** If they join later, they need their own `phase → rules` mapping,
   not session presets.
5. **Per-set statistics.** No need yet; they can be derived from the view without
   a new migration if requested.

---

## Appendix A: full snapshot example

New MAJADU 30 session:

```json
{
  "scoring_preset": "majadu30",
  "scoring_rules": {
    "id": "majadu30",
    "label": "MAJADU 30",
    "mode": "preset",
    "gamesToWin": 1,
    "pointsToWin": 30,
    "winBy": 1,
    "deuceAt": null,
    "maxPoints": 30,
    "changeEndsAt": 15
  }
}
```

New Classic 21 session:

```json
{
  "scoring_preset": "classic21",
  "scoring_rules": {
    "id": "classic21",
    "label": "Classic BO3 21",
    "mode": "preset",
    "gamesToWin": 2,
    "pointsToWin": 21,
    "winBy": 2,
    "deuceAt": 20,
    "maxPoints": 30,
    "changeEndsAt": 11
  }
}
```

## Appendix B: example reader queries after the migration

Board (session projection):

```sql
select e.source_id::text as source_id, e.local_date::text as local_date,
       r.round_no, r.court_no, r.winner, r.points_a, r.points_b,
       coalesce((s.scoring_rules->>'pointsToWin')::int, $4)::int as target
from rating.events e
join session.game_results r
  on r.community_id = e.community_id and r.session_id = e.source_id
join session.sessions s
  on s.community_id = e.community_id and s.id = e.source_id
where e.community_id = $1::uuid and e.event_type = 'session'
  and e.local_date >= $2::date - ($3::int * 7)
  and e.local_date <= $2::date
  and s.approved_at is not null
  and r.status = 'played' and r.winner <> ''
order by e.local_date, r.round_no, r.court_no;
```

Achievement:

```sql
select r.session_id::text as session_id,
       r.round_no, r.court_no, r.winner,
       coalesce(g.side_a1::text, '') as a1, ...
from session.game_results r
join session.games g
  on g.community_id = r.community_id and g.session_id = r.session_id
 and g.round_no = r.round_no and g.court_no = r.court_no
join session.sessions s
  on s.community_id = r.community_id and s.id = r.session_id
where r.community_id = $1::uuid
  and r.status = 'played' and r.winner <> ''
  and s.approved_at is not null
  and s.status in ('locked', 'published', 'completed', 'archived');
```

## Appendix C: key numbers summary

| Item | Before | After |
|---|---|---|
| Session rating target | 21 (all) | `pointsToWin` snapshot: 30/21/15 |
| Points 30–28 | 136.90 | 133.33 |
| Points 30–5 | 250.00 | 229.17 |
| BO3 match 21–19, 21–19 | none | 136.90 |
| BO3 match 21–19, 19–21, 21–19 | none | 128.97 |
| Game count per BO3 match | none | 1 |
| Board entries per session | 1 | 1 |
| best-N | 10 | 10 |
| Standings shape | same | same |