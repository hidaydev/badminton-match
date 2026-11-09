# Product Overview

## Purpose

Majadu is a badminton operations app for one or many communities. Its focus:

- running play sessions (participants, schedule, scores, standings),
- recording match and tournament results,
- computing the player points board,
- preparing publication material from session/tournament results.

Questions the app answers:

- Who plays today and who is absent?
- Which games are played, on which court, and what are the scores?
- Who leads the session standings and the community points board?
- What are the results of classic or team tournament groups/brackets?
- Which publication images can be downloaded from those results?

## Community model & access

- One instance serves many communities. Every operational row is owned by one
  `community_id`.
- Login uses Google OIDC; there are no anonymous writes. The session cookie is `HttpOnly`.
- Roles per community: `member` (read), `host` (write sessions/tournaments), `admin` (members,
  settings, rating, claims). Platform owner is only for platform management.
- Share links `/s/{code}` are read-only and grant no write access.

## Language and locale

The supported locale is **English (`en`)**. It is a product limit, not an
oversight:

- `apps/web/src/i18n/en.ts` is the only dictionary (ADR-006). Every new string
  goes there; a component imports `t` instead of writing a literal.
- The browser language is not negotiated, and there is no locale switch. A
  second locale needs a second dictionary and a decision about who translates
  it, which is why it is a release decision rather than a code change.
- The legacy tree still contains literal English copy. Those screens are
  scheduled for the rewrite, so a lint rule that fails on every literal in
  `apps/web/src/legacy` would be red until then. The accepted limit is
  recorded as RSK-005 in `docs/handbook/requirements.md`.

Names, comments and announcements entered by users are free text and are not
translated; the interface labels around them are. Any future locale has to keep
that distinction.

## Product areas

### 1. Sessions

Session data: title, date, start time, slot duration, courts, participants, and games.

- The schedule is stored relationally: one `session.games` row per `{round}-{court}`, with
  up to two players per side (`session.participants`).
- A game's score is changed through `PATCH …/games/{gameKey}`; a game is skipped through
  `…/games/{gameKey}/skip`. Scores must be 0–99 and must not be a draw.
- Absence is marked per participant; absent players are not counted in the standings and get
  no points.
- Locking a session records who/when approved; unlock is available to host/admin.
- Session standings are computed on the server: wins, point difference, points for, then name
  (`modules/session/standings.nim`).

**UI status:** the session list and detail already exist. Host/admin get a panel for
lock/unlock, share link, scores, skip, absent, and swap. Creating a new session and building
the schedule goes through a 4-step wizard (`/c/:slug/session/new` → `/session/players`
→ `/session/constraints` → `/session/generate`) with a 5-phase schedule generator in the
browser.

### 2. Players

- Primary identity is `canonical_name`; search/import uses `alias`, which is normalized and
  unique per community.
- 8 tier levels: `D`, `D+`, `C`, `C+`, `B`, `B+`, `A`, `A+`; may be empty.
- Gender `M`/`F`.
- Player claim by account: one `pending` claim per player, one owned player per account per
  community; claim decisions are made by an admin.
- Merge moves aliases, claims, rating snapshots, achievements, pairs (together with their
  `display_name`), rating state, and session history (participants, games, skips, team
  players) to the target player, then deletes the source. Merge is rejected when the pair that
  names both players is already used by a match, or when both appear in the same game.
- Player statistics and badges are available through the API; the player list page, claims, and
  the admin decision queue are already built (`apps/web/src/pages/PlayersPage.tsx`).

### 3. Points board

- Points are computed from session games and tournament matches within a rolling **12-week**
  window, taking the **best 10 entries** per player (one entry per session/tournament).
  `min_sessions` filters the board; below `rating.thin_evidence_n` a player is marked as thin
  evidence, not hidden.
- Game value = `session_base × (0.5 + 0.5 × clamp(margin/score_target, -1, 1))`.
- Tournaments with an active ladder (`rating.levels`) use
  `champion_points × round_ratio(placement)`; without a ladder, the game formula is used.
- Opponent strength multiplier = ratio of the opponent's average tier to the population,
  clamped to `0.5–1.5`.
- All numbers come from community/platform config (`rating.*`).
- The community board is capped by `rank.board_limit` (200 rows) and can be filtered by tier.
- There is no absolute/Glicko rating and no season cycle.
- Player detail: rank, points, played/won/lost, statistics, and badges.
- Session/tournament result ingest is idempotent; a source has sign-off, and revert rejects a
  source that is already finalized.

### 4. Achievement

Badges are computed by the backend from player history and the catalog in
`achievement.definitions`:

- categories: `attendance`, `volume`, `opponent`, `tournament`, `tier`, `rank`, `social`;
- the key determines the metric + threshold (e.g. `sessions:10`, `games:25`, `rank:3`);
- badges appear at `/c/{slug}/rankings/{playerId}`;
- a key that is not in the seed cannot be earned (`achievement.earned` FK to the definition).

### 5. Tournaments

**Classic:** 16 pairs → 4 groups (A–D) → round-robin → knockout. One tournament has
32 matches: 24 group, 4 QF, 2 SF, 1 third-place playoff, 1 final. The draw is made in the
browser from seeds, then saved through the API.

**Team:** 6 teams × 6 classes (`A+`…`C`), 9 round-robin group matches + 1 final, 3 rubbers per
match. The courts per match can be edited; standings and champion are computed from the same
domain rules.

An admin can finalize a source, ingest, revert rating, and delete a tournament.

### 6. Social export

- Sources: session standings, classic group/bracket/final, or team standings/final.
- Two variants: `post` (default 1080×1350) and `story` (default 1080×1920).
- Sizes use the constants in `apps/web/src/legacy/config/canvas.ts`
  (`POST_WIDTH`/`POST_HEIGHT`, `STORY_WIDTH`/`STORY_HEIGHT`), not config.
- Rendered in the browser canvas; the result is downloaded as an image.

### 7. Communities & operations

- Invites go through email-hash + token; join requests can be opened/closed per community.
  The `/invites/{token}` link can be accepted directly by the address it targets (login also
  claims that invite), and re-acceptance by the same address is idempotent.
- Community settings are overrides of the platform registry; an override may only narrow the
  platform value.
- Append-only audit records privileged actions (actor, target, result, before/after), with a
  field allowlist so share codes/emails/IPs do not enter the evidence.
- CLI operations: `./task bootstrap`, `ingest`, `ranksnapshot`, `janitor`, `opstoken`,
  `audit-retention` (`task`).

## Realtime

Session changes are broadcast over WebSocket with a single-use ticket. The `session.changed`
frame only signals that state changed (it carries `seq`), it does not send a delta; clients
must re-read the session. There is no SSE and no event replay.
The frontend uses WebSocket on the in-app session screen (`useSessionRealtime`,
with 5-second polling while the socket is not yet connected); the public share page
`/s/{code}` does not open a socket and reloads every 10 seconds.

## Architecture summary

- **Frontend**: React 19, Vite, Tailwind 4, React Router 7 (`apps/web`).
- **Backend**: Nim 2.4, Mummy HTTP + WebSocket, `db_connector` (`apps/api/src`).
- **Database**: PostgreSQL 18, database `bm2`, schema per domain (`db/migrations`).
- **Contract**: hand-written OpenAPI + codegen, 75 operations
  (`packages/contracts/openapi`).

Details: [`architecture.md`](architecture.md) · [`data-model.md`](data-model.md) ·
[`features-and-routes.md`](features-and-routes.md).
