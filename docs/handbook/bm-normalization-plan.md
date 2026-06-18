# BM Normalization Plan

Last updated: 2026-06-17

This document proposes a careful migration from the current snapshot-first
`badminton_match` schema to a new normalized schema `bm`.

Scope in this phase:

- normalize the operational session domain first
- adopt canonical player + alias modeling now
- do not port `mdef` analytics/ELO yet
- do not cut over production traffic yet
- do not mutate the existing `badminton_match` schema in place

## Executive Summary

The current production-backed model stores sessions and tournaments as JSON
snapshots. That was the right migration choice from Google Sheets because it
preserved behavior and reduced risk, but it is not a good long-term model for:

- partial updates
- consistency constraints
- player identity resolution
- queryability
- future integration with `mdef`

The recommended path is:

1. keep `badminton_match` unchanged as the legacy production layer
2. create a new schema `bm`
3. model players canonically in `bm.players`
4. resolve all known name variants through `bm.player_aliases`
5. normalize sessions, games, and scores into relational tables
6. backfill legacy snapshot data from `badminton_match` into `bm`
7. verify parity before any frontend cutover

## Current State

## Existing `badminton_match` schema

The current application uses three tables:

- `badminton_match.sessions`
- `badminton_match.tournaments`
- `badminton_match.session_exports`

The active product behavior is almost entirely driven by the `snapshot jsonb`
payload stored in `sessions` and `tournaments`.

Operationally relevant RPCs today:

- `bm_publish_session`
- `bm_get_session`
- `bm_list_sessions`
- `bm_list_players`
- `bm_get_player_stats`
- `bm_publish_tournament`
- `bm_get_tournament`

These RPCs scan or rewrite snapshots rather than operating on normalized rows.

## Existing session snapshot semantics

The current session snapshot contains:

- `session`
- `players`
- `fixMatches`
- `schedule`
- `playedGames`
- `gameScores`
- optional `absentPlayers`

The current model treats session players as free-form operational records with:

- session-local `id`
- `name`
- `gender`
- `tier`

This is sufficient for scheduling and live operations, but not sufficient for
global identity control.

## Existing tournament snapshot semantics

The tournament feature is also snapshot-first:

- pairs
- groups
- group and knockout matches
- bracket propagation state

Tournament normalization is intentionally deferred in this plan to avoid mixing
two migrations at once.

## Identity Lessons From `mdef`

The most reusable part of `mdef` for this phase is its player identity model.

`mdef` uses:

- `public.players`
- `public.player_aliases`
- `public.match_history`

Important patterns worth adopting:

1. `players.canonical_name` is the global human-facing identity
2. `player_aliases.alias_name` is stored lowercase and trimmed
3. each alias points to exactly one canonical player
4. ingestion resolves names through the alias table before processing matches
5. canonical names also get registered as aliases to themselves

Important patterns not adopted yet in this phase:

- ELO fields
- lifetime leaderboard aggregates
- `match_history`
- analytics or admin auth behavior

This phase copies the identity and alias discipline, not the full `mdef`
analytics model.

## Core Decision: Canonical-Only Players

This plan assumes:

- there will be no separate "session-local identity player" entity
- every player in a normalized session must reference a canonical
  `bm.players.id`
- all naming variation is handled through `bm.player_aliases`

This is stricter than the current snapshot model, but it is aligned with the
desired end state and with `mdef`'s alias-driven ingestion model.

Important nuance:

- `bm.session_players` still exists
- but it is a membership table, not a separate identity table
- it links a session to a canonical player
- it can hold session-scoped facts such as absence or replacement metadata

It does not own a separate player identity beyond the canonical `player_id`.

## Scope Boundaries

In scope now:

- canonical players
- aliases
- sessions
- court availability
- session membership
- fixed constraints
- scheduled games
- game-player assignments
- scores and played status
- backfill from legacy snapshots

Out of scope now:

- `mdef` ELO/ranking port
- tournament normalization
- auth and RLS hardening for the new schema
- full frontend cutover
- shared operational/analytics schema merger

## Target Schema Overview

The `bm` schema should be split into:

1. identity layer
2. operational session layer
3. compatibility/export layer

## Identity Layer

### `bm.players`

Canonical player registry.

Suggested fields:

- `id uuid primary key default gen_random_uuid()`
- `canonical_name text not null unique`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`

Deliberately omitted for this phase:

- ELO
- wins/losses aggregates
- points
- match history derived metrics

Reason:

- this schema is for operational normalization first
- analytics fields would create misleading ownership too early

### `bm.player_aliases`

Alias lookup table.

Suggested fields:

- `alias_name text primary key`
- `player_id uuid not null references bm.players(id) on delete cascade`
- `created_at timestamptz not null default now()`

Rules:

- `alias_name` must always be stored as `lower(trim(name))`
- a canonical name should also exist as an alias
- one alias maps to exactly one player
- alias reassignment is allowed only through controlled admin-style flows

Recommended supporting function:

- `bm.normalize_player_name(text) returns text`

This should at minimum:

- `trim`
- `lower`
- collapse repeated internal whitespace

This function should be used in:

- alias inserts
- alias lookups
- backfill matching
- any future import pipeline

## Operational Session Layer

### `bm.sessions`

Session header.

Suggested fields:

- `id text primary key`
- `title text not null default ''`
- `session_date date not null`
- `session_start time not null`
- `slot_minutes integer not null check (slot_minutes > 0)`
- `status text not null`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`

Suggested `status` values:

- `draft`
- `locked`
- `published`
- `completed`
- `archived`

### `bm.session_courts`

Per-session court availability.

Suggested fields:

- `id bigserial primary key`
- `session_id text not null references bm.sessions(id) on delete cascade`
- `court_index integer not null`
- `court_name text not null default ''`
- `start_time time not null`
- `end_time time not null`

Constraints:

- unique `(session_id, court_index)`
- `end_time > start_time`

### `bm.session_players`

Membership of canonical players in a session.

Suggested fields:

- `id bigserial primary key`
- `session_id text not null references bm.sessions(id) on delete cascade`
- `player_id uuid not null references bm.players(id)`
- `gender text not null check (gender in ('M', 'F'))`
- `tier integer not null check (tier between 1 and 4)`
- `is_absent boolean not null default false`
- `replacement_note text not null default ''`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`

Constraints:

- unique `(session_id, player_id)`

Important note:

- gender and tier remain copied into this membership row because they are
  operational session attributes in the current product
- this allows session truth to remain stable even if future canonical-player
  metadata evolves separately
- compatibility metadata such as legacy `player_ref` and imported
  `source_name` may also live here purely for deterministic backfill and
  legacy-shaped snapshot reconstruction

### `bm.fix_matches`

Session-scoped fixed match containers.

Suggested fields:

- `id bigserial primary key`
- `session_id text not null references bm.sessions(id) on delete cascade`
- `sort_order integer not null default 0`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`

### `bm.fix_match_slots`

Four slots per fixed match.

Suggested fields:

- `id bigserial primary key`
- `fix_match_id bigint not null references bm.fix_matches(id) on delete cascade`
- `slot_index integer not null check (slot_index between 0 and 3)`
- `session_player_id bigint null references bm.session_players(id) on delete set null`

Constraints:

- unique `(fix_match_id, slot_index)`

This preserves the current "partially specified game" behavior:

- null slot means open slot
- filled `[0,1]` with null `[2,3]` means "pair together, opponents open"

### `bm.scheduled_games`

Scheduled games per session.

Suggested fields:

- `id bigserial primary key`
- `session_id text not null references bm.sessions(id) on delete cascade`
- `slot_index integer not null`
- `court_index integer not null`
- `status text not null`
- `source text not null`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`

Suggested `status` values:

- `scheduled`
- `played`
- `cancelled`

Suggested `source` values:

- `generator`
- `manual`
- `constraint`

Constraints:

- unique `(session_id, slot_index, court_index)`

### `bm.scheduled_game_players`

Two teams of two players per game.

Suggested fields:

- `id bigserial primary key`
- `scheduled_game_id bigint not null references bm.scheduled_games(id) on delete cascade`
- `session_player_id bigint not null references bm.session_players(id)`
- `team text not null check (team in ('A', 'B'))`
- `position integer not null check (position in (0, 1))`

Constraints:

- unique `(scheduled_game_id, team, position)`
- unique `(scheduled_game_id, session_player_id)`

This table should reference `session_players`, not `players`, because:

- it enforces that every scheduled player belongs to the session
- it keeps absence and membership checks local
- it still guarantees canonical identity through `session_players.player_id`

### `bm.game_scores`

Game score storage.

Suggested fields:

- `scheduled_game_id bigint primary key references bm.scheduled_games(id) on delete cascade`
- `score_a integer not null`
- `score_b integer not null`
- `entered_at timestamptz not null default now()`

Constraints:

- `score_a >= 0`
- `score_b >= 0`
- `score_a <= 99`
- `score_b <= 99`
- `score_a <> score_b`

## Played State Decision

This is a critical semantic decision because the current app has both:

- explicit `playedGames`
- optional `gameScores`

These are not exactly the same thing.

Current product behavior allows:

- a game marked played without a score yet
- score entry to implicitly mark a game played

Because of that, `played` should not be inferred solely from score existence.

Recommended solution:

### `bm.game_progress`

Suggested fields:

- `scheduled_game_id bigint primary key references bm.scheduled_games(id) on delete cascade`
- `is_played boolean not null default false`
- `updated_at timestamptz not null default now()`

This preserves current UI semantics exactly.

## Explicitly Deferred Tables

The following are intentionally not part of the first normalized cut:

- tournament tables
- analytics tables
- match-history export tables modeled after `mdef`

Reason:

- session normalization already has enough complexity
- tournament is smaller but structurally different
- analytics introduces domain ownership decisions that should be made later

## Name Resolution Strategy

Canonical-only sessions require a strict resolution path.

### Resolution rule

For every legacy or incoming player name:

1. normalize with `bm.normalize_player_name`
2. look up in `bm.player_aliases.alias_name`
3. resolve to exactly one `player_id`
4. if not found, mark unresolved
5. do not silently guess or fuzzy-merge

### Why strict resolution is required

The current data includes many realistic risks:

- case variation
- abbreviations
- shortened nicknames
- punctuation variation
- probable misspellings
- potential duplicate humans with similar names

Automatic fuzzy matching is dangerous because a wrong canonical merge is harder
to repair than a temporarily unresolved name.

### Suggested unresolved policy

During backfill or future imports:

- unresolved names do not get silently inserted into normalized session tables
- they go into a review report
- once resolved, they become aliases or new canonical players
- then the backfill/import can continue deterministically

This mirrors the discipline already present in `mdef`'s alias scan and merge
workflow.

## Backfill Design

Backfill source:

- `badminton_match.sessions.snapshot`

Backfill target:

- `bm.*`

Backfill should be:

- repeatable
- idempotent
- deterministic
- validation-heavy

### Recommended backfill order

1. stage legacy session rows
2. extract all distinct player names from snapshots
3. normalize names
4. resolve names through `bm.player_aliases`
5. produce unresolved-name report
6. stop if unresolved names exist and strict mode is enabled
7. insert session headers
8. insert session courts
9. insert session memberships through canonical `player_id`
10. insert fix matches and slots
11. insert scheduled games
12. insert scheduled game players
13. insert played state
14. insert scores

### Why alias resolution comes before session insert

Because the target model assumes:

- no free-form player identity in sessions
- every participation row must be canonical

So resolution is not a post-processing step; it is a prerequisite.

## Legacy Data Hazards To Audit

The backfill SQL already suggests that real prod-ish data contains:

- case differences like `visi` vs `Visi`
- shortened names like `Agh`
- punctuation variants like `Mr. Hong`
- probable spelling variants like `Didick` vs `Didik`
- tournament pair names that may require splitting conventions

Before final backfill, the following audit report should exist:

- normalized name frequency
- unresolved normalized names
- names mapping to multiple plausible canonicals
- sessions with duplicate participant names after normalization

## RPC Strategy

The new schema should use new RPCs rather than overloading the legacy ones.

### Naming convention

Use schema-qualified RPC functions in `bm`, while keeping them logically
separate from the old public `bm_*` functions.

Recommended examples:

- `bm.publish_session`
- `bm.get_session`
- `bm.list_sessions`
- `bm.set_game_played`
- `bm.set_game_score`
- `bm.swap_game_players`
- `bm.swap_games`
- `bm.set_player_absence`
- `bm.replace_session_player`

If schema-qualified PostgREST RPC calling becomes awkward in the client layer,
the fallback is:

- expose thin `public.*` wrappers
- wrappers call into `bm.*`
- but implementation ownership remains in `bm`

### Native write RPCs

These should operate on normalized tables directly and run transactionally:

- create or publish session
- update played state
- update score
- swap players
- swap games
- mark absence
- replace player

### Compatibility read RPCs

To reduce frontend cutover risk, the new backend should also be able to
reconstruct a legacy-shaped view:

- session
- players
- fixMatches
- schedule
- playedGames
- gameScores
- absentPlayers

This allows the frontend query layer to migrate gradually even after data is
written to normalized tables.

Recommended examples:

- `bm.get_session_snapshot_compat`
- `bm.list_players_compat`
- `bm.get_player_stats_compat`

These RPCs are compatibility tools, not the long-term ideal API.

## Verification Plan

No frontend cutover should happen before parity is checked.

### Required parity checks

For a representative sample and eventually all sessions:

- session count parity
- session title/date parity
- court count and availability parity
- participant count parity
- fix match count parity
- scheduled game count parity
- played-game count parity
- score count parity
- absence parity

### Derived behavior checks

The following should also match:

- standings computed from normalized rows vs current snapshot logic
- session list ordering
- player list output
- player stats output for sampled players

### Identity checks

- every canonical player has a self-alias
- no duplicate aliases
- no alias points to multiple players
- no session row references a non-existent canonical player

## Rollout Plan

### Phase 1

- audit legacy data
- audit naming drift
- finalize schema decisions

### Phase 2

- create `bm` schema tables
- create helper functions
- create native RPCs

### Phase 3

- build backfill script
- resolve aliases
- run backfill in staging

### Phase 4

- build compatibility read RPCs
- compare old and new outputs

### Phase 5

- cut over one feature area at a time in the frontend
- keep `badminton_match` untouched during transition

## Open Decisions

These decisions still need explicit confirmation before SQL implementation:

1. Should `bm.players` include any non-identity metadata now?
   Recommendation:
   no, keep minimal for this phase.

2. Should unresolved names hard-fail backfill?
   Recommendation:
   yes in production-grade runs, but allow report-only mode during discovery.

3. Should `replace player` mutate membership rows or append replacement events?
   Recommendation:
   start with membership mutation plus audit note; event history can come later.

4. Should tournaments be normalized in the same migration set?
   Recommendation:
   no, defer until session domain is stable.

5. Should the new RPC layer be schema-qualified `bm.*` only or exposed via
   `public` wrappers?
   Recommendation:
   implementation in `bm`, wrappers only if PostgREST ergonomics require them.

## Immediate Next Steps

1. Produce a legacy player-name audit from `badminton_match.sessions.snapshot`
2. Draft the concrete `bm` DDL
3. Draft the exact RPC signatures
4. Draft backfill mapping SQL
5. Verify a small sample manually before full backfill

## Bottom Line

The safest and cleanest path is:

- `badminton_match` stays frozen as legacy prod storage
- `bm` becomes the normalized operational schema
- identity is canonical-only from day one in `bm`
- aliases are mandatory infrastructure, not a later enhancement
- unresolved names are reviewed, not guessed
- frontend cutover happens only after relational parity is proven
