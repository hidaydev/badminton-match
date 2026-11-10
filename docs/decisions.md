# Architecture Decision Records

Architecture and product decisions are recorded here so the same findings are not
raised again in every audit. Two kinds of entry:

- **Applied**: decisions that were taken and already have a commit (the shape of
  the fix, not merely "this is not a bug").
- **Deferred**: findings that are valid but deliberately not worked on now.

Each entry states the reason and what would reopen that decision.

Format: `## ADR-<number> · <title>`, with Date, Status, Decision, Reason,
Reopener.

---

## ADR-001 · `rank_streak` medals start being recorded in v2, not replayed

**Date:** 2026-11-05
**Audit finding:** BE-10
**Status:** Applied

**Decision:** v2 starts writing `rank_streak:<run>` from the ranking history
recorded since migration `0025`, without replaying the past. The owner chose
"data source going forward", not reconstructing the board for each session date.

**Shape:** `rating.snapshots` gets a `rank` column (nullable: old rows have no
ranking, and inventing one would claim a position that was never displayed).
`./task ranksnapshot` writes that column together with the points. `backfill`
runs over community event dates; every date without a snapshot row breaks the
run (an unrecorded ranking is not proof of staying on top), and the longest run
with rank ≤ 3 becomes a single `rank_streak:<n>` row.

**Reason:** a run can only be measured from rankings that were actually recorded;
reconstructing an "as-of" board for every session date means one pass over the
entire history and still guessing the window that applied at the time.

**Existing values are preserved:** `rank_streak:*` rows from the v1 import carry
runs measured by the v1 board and cannot be recomputed by v2. So the writer takes
the maximum between the new run and the existing row, so that no medal goes down
and each player still has exactly one row. `tournament:<uuid>` is still untouched
by reconciliation (ADR-002).

**Reopener:** `ranksnapshot` runs as a production timer for at least 12 weeks,
after which the run can be considered complete and the maximum rule can be
replaced by full reconciliation.

---

## ADR-002 · Medal reconciliation revokes instead of storing history

**Date:** 2026-11-05
**Audit finding:** BE-31
**Status:** Applied (`4024969`)

**Decision:** when a rating is reverted or rebuilt, catalog medals that no longer
meet the threshold are **deleted**; medals that meet the threshold again are
recorded with a new `earned_at`.

**Reason:** medals are a projection of match data, not an independent record. If
the session they are based on is revoked, keeping the medal would make the awards
board lie. A new date for a medal that is earned again is honest: it really was
earned again. Rows outside the catalog (`tournament:<uuid>` import and
`rank_streak`) are untouched because v2 cannot compute them (ADR-001).

**Reopener:** there is a need to show a "previously earned" history; at that point
a separate history table is needed, not the `earned` table.

---

## ADR-003 · `rating.levels` is operator data, not config

**Date:** 2026-11-05
**Audit finding:** BE-32
**Status:** Applied (`4c10e85`)

**Decision:** the tournament points ladder (`champion_points`, `round_ratios`) is
filled by the operator through `./task levels`; a community without a row uses
the per-game formula.

**Reason:** ladder numbers are a business decision per community, not an
application constant. Seeding them automatically would mean inventing numbers.
The shape is a table (not a key registry) because its content is nested JSON and
differs per tournament type. The per-game formula stays so that a new community
has points immediately without waiting for an operator.

**Reopener:** the ladder should be managed from the admin UI rather than the CLI;
at that point routes + contract changes are needed.

---

## ADR-004 · One exposed point number; the ledger stays internal

**Date:** 2026-11-06
**Audit finding:** BEP-10
**Status:** Applied (stage 1 + stage 2)

**Decision:** the API exposes only **one** point number: the board row (tier
projection). `GET .../players/{id}/stats` no longer reads
`rating.player_state.rating`; `points` is filled from the same `boardEntry` as the
board, and a player without an entry in the window gets 0. At that point
`rating.deltas` / `player_state.rating` were left as an internal ledger for
opponent weighting in ingest, and never became a number seen by users (stage 2
then removed them, see below).

**Reason:** two numbers for the same player are a visible defect (median
difference 756 points in dev data; 31% of players shift >10 ranks). But
standardising the *formula* would mean recomputing every delta/state for all
communities and invalidating the comparison against the v1 import: high risk with
no visible benefit. Closing the exposure path removes the inconsistency without
touching a single stored number.

**Stage 2 (applied):** `rating.deltas` is dropped and `player_state.rating` is
discarded by migration `0026_drop_rating_ledger.sql`. Before the drop, the
migration backfills `rating.events.point_entries` from the number of delta rows
per event: the only thing still used (rating source screen, revert/rebuild
report, `deltas` in the API response). Ingest, tournaments, and import now only
write the counter through `addState`; merge no longer moves delta rows; readiness
no longer checks tables that no longer exist. The visible number does not change:
the board is still a projection, and `deltasMoved` is still reported as 0.

**Reason:** after stage 1, the only reader of `player_state.rating` was ingest
itself (opponent weighting), and even that was already recomputed on every
rebuild. Storing a value that is only used by its own writer forces a rebuild to
replay events in approval order in order to reproduce a number that is not read:
cost and a source of drift with no benefit.

**Reopener:** a need appears that genuinely requires raw rating accumulation per
game (e.g. tournament seeding), so the ledger has to be revived as a new table
with clear readers.

---

## ADR-005 · Empty state + join request flow

**Date:** 2026-11-05
**Audit finding:** UX-10
**Status:** Applied (`d95247a`)

**Decision:** an account without a community gets one action that is actually
available: platform owners are directed to create a community, other accounts
send a join request (`POST /c/{slug}/join-requests`, always 202).

**Reason:** the old hint told accounts that did not have that right to "create a
community". A uniform 202 response is anti-enumeration protection, so the screen
may only state "sent", not "community found".

**Reopener:** there is a link-based invitation flow that needs to be shown on the
same screen.

---

## ADR-006 · One i18n dictionary, one locale

**Date:** 2026-11-05
**Audit finding:** UX-14
**Status:** Applied (`e5421fc`)

**Decision:** `apps/web/src/i18n/en.ts` is the only dictionary. The second
dictionary (`src/legacy/i18n`) is removed; template callers use `t(key, vars)`.
`<html lang="en" dir="ltr">` is static.

**Reason:** two dictionaries mean two places for every addition of text and one
recurring audit finding. Only English is active, so translating dates to the
browser locale would make the English UI contain dates in another language;
`formatLongDate` centralises that decision in one function.

**Reopener:** a second language is actually worked on; at that point `en.ts`
becomes `en.ts` + `id.ts` and `t()` selects a dictionary.

---

## ADR-007 · Metrics live in an internal listener, not on the public port

**Date:** 2026-11-05
**Audit finding:** OPS-09
**Status:** Applied

**Decision:** `/metrics` still does not exist on the public port (`smoke.sh`
keeps it at 404). The request counter registry is incremented on the single
response path and rendered by a second listener that binds only `127.0.0.1`,
enabled through `MAJADU_METRICS_PORT` (empty/0 = off). Every response also writes
one structured access log line (`method`, route template, `status`) through the
logger that already redacts sensitive values.

**Reason:** counters that are never incremented/rendered are not observability. A
loopback listener does not add public surface, and labels use route templates so
that share codes, slugs, and ids do not become series; unmatched paths are merged
into one bucket so that a scanner cannot grow the registry without bound.

**Evidence on the VPS** (the image does not contain `curl`):

```bash
podman exec majadu-api bash -c \
  'exec 3<>/dev/tcp/127.0.0.1/9090; printf "GET /metrics HTTP/1.0\r\n\r\n" >&3; cat <&3'
```

**Reopener:** a collector exists on the VPS; at that point it is enough to add
port publishing or scrape config, not to change code.

---

## ADR-008 · Board projection reads without a transaction

**Date:** 2026-11-05
**Audit finding:** BEP-03
**Status:** Applied

**Decision:** `projection.project` is no longer wrapped in `db.tx`. Every
statement uses `db.query`/`db.read`, which borrows one connection and then returns
it, and aggregation runs after no connection is held. The pool still leaves two
connections per process (`apps/api/src/main.nim`) for nested `Db` calls.

**Reason:** with a pool sized to the number of workers, one board that holds a
connection for the whole aggregation reduces capacity for every other request.
READ COMMITTED gives each statement its own snapshot, so an outer transaction does
not add meaningful consistency for this point-in-time report.

**Reopener:** the board needs a truly uniform snapshot across statements (e.g. a
guard against a concurrent rebuild); at that point use an explicit
`repeatable read` transaction, not plain `db.tx`.

---

## ADR-009 · `breakdown` on every board row is not a v2 regression

**Date:** 2026-11-05
**Audit finding:** BEP-07
**Status:** Revoked

**Decision:** no payload change. The finding is closed, not worked on.

**Reason:** v1 also sent `breakdown` on every row (`RankPointRow` in
`.local/old-src/apps/web/src/queries/endpoints.ts`, the endpoint only accepted
`limit` and `min_sessions`). So v2 adds nothing that did not already exist; this
is a payload optimisation that nobody has asked for, not a parity defect. The
"regression" claim in the audit is unproven.

---

## ADR-010 · Two state owners stay; the real leaks are closed

**Date:** 2026-11-05
**Audit finding:** FE-13
**Status:** Applied (leak scope, not unification)

**Decision:** Zustand still holds the generator draft and the query cache still
holds the server snapshot. What was fixed are the two paths that made that dual
ownership corrupt data:

1. Share links no longer write to the draft. The decoded result snapshot is the
   single owner of the spectator screen; all handlers stop before touching the
   store, and the summary modal receives `readOnly`.
2. The draft's base version is stored too (`cloudVersion`). Previously the version
   existed only in the query cache; after a reload the cache was empty, and the
   next publish used the latest server version and overwrote scores changed by
   another host. Now `If-Match` uses the draft version, and a conflicting publish
   still fails until the user reloads.

**Reason:** unifying the whole wizard into the query cache is a routing refactor
and dozens of components with a large regression risk, while the reported damage
came from the two narrow paths above and could be closed without touching the
generate flow.

**Reopener:** an offline draft and a server snapshot need to be merged for a new
feature (e.g. offline editing), or a path that needs a single source of truth
appears again.

---

## ADR-011 · Home page stays as it is now

**Date:** 2026-11-05
**Audit finding:** UX-03
**Status:** Revoked

**Decision:** the home page is unchanged. The owner rejected the proposal for
today's sessions + my rank/medals.

**Reason:** "my rank" and "my medals" require an account → player link that is not
mandatory, so the shape of the home page would differ between accounts without an
agreed product rule. Shortcuts and last sessions already answer the main need;
adding a personal block without a product decision only moves complexity into the
UI.

**Reopener:** the owner decides the rule for accounts without a claim (e.g.
asking for a claim first, or choosing a default player).
---

## ADR-012 · Score format per session (preset + snapshot)

**Date:** 2026-11-06
**Status:** Accepted

**Decision:** one schedule slot is one match consisting of 1..N sets (MAJADU 30,
Classic BO3 21, New BWF BO3 15). Each session stores a snapshot of
`scoring_preset` + `scoring_rules`; the preset list is platform config
(`session.scoring_presets`) and the community default is
`session.default_scoring_preset`. Match results are stored in `session.game_sets`
and read through the `session.game_results` view.

Old sessions (v1) get a `legacy_v1` snapshot with target 30, because those
sessions really were played to 30. The old rating that used
`rating.score_target = 21` was a bug; because points are projected at read time,
the correction is retroactive without a data migration.

Points per match stay 250 before the multiplier. What changes is only the split
between winner and loser for BO3 matches, because the margin is normalised per
set:

```
r = Σ(a−b) / (pointsToWin × setsPlayed)
value = gameValue(base, r × pointsToWin, pointsToWin)
```

**Reason:** the format must be selectable without changing the application;
storing a snapshot prevents future config edits from rewriting historical results;
and one `game_sets` row per set makes the winner computed from sets, not from
total points (total points can be misleading in BO3). `rating.score_target` stays
only as a fallback for rows without a snapshot and is removed after two releases;
the `session.games.score_a/score_b` columns are also kept until rollback is no
longer needed.

**Consequences:** the board can move once at deploy (target 21 → 30); old daily
snapshots are not rewritten, so `prevRank`/`rankDelta` may show a one-time
movement. `./task ranksnapshot` is run after deploy so that the snapshot for that
day uses the new numbers.

**Reopener:** tournaments come into scope for per-session formats, or a format
appears that needs rules outside
`gamesToWin/pointsToWin/winBy/deuceAt/maxPoints` (e.g. side-out scoring).

---

## ADR-013 · The scoreboard exports the match but does not sync it

**Date:** 2026-11-09
**Audit finding:** PWA-02
**Status:** Applied (export) / Deferred (cross-device sync)

**Decision:** the standalone scoreboard keeps the in-progress match in this
browser and offers an explicit export: one control copies a JSON object with the
four stored keys (`score-red`, `score-blue`, `name-red`, `name-blue`) through the
native share sheet, or the clipboard when the sheet is not available. There is
no import, no write to the platform and no cross-device sync.

**Reason:** the app has no API client, so a queued write needs a sync contract
that does not exist, and an import format for a second device is a product
decision that has not been made. Export covers the case the audit can prove,
losing the only copy when site data is cleared, without inventing either
contract. Requesting persistent storage on the first score makes eviction less
likely without committing to a shape.

**Reopener:** the owner decides that courtside scores must land on the platform
or move to a second device; that needs an API client or an import control, plus
a test that round-trips the four stored keys through whichever format is chosen.

---

## ADR-014 · CI runs on a pinned Ubuntu image, and installs what the toolchain loads

**Date:** 2026-11-09
**Audit finding:** QA-01
**Status:** Accepted

**Decision:** every job under `.github/workflows/` pins `runs-on: ubuntu-24.04`,
and every job that runs a Nim binary installs `libpcre3` before it does.

**Reason:** the `ubuntu-latest` label moved to Ubuntu 26 on 2026-10-19. The first
Linux run of the release gate showed that the new image does not ship PCRE 1,
which Nim's `re` module binds at run time, and that the pinned lcov build could
not load its Perl modules. Pinning keeps the gate on an image the toolchain is
validated against; installing the library explicitly keeps the jobs working when
the pin moves, and a shelltest now fails a workflow that runs `deps-install`
without it.

**Reopener:** the toolchain binds PCRE 2 instead of PCRE 1, or the gate is proven
green on a newer image. Change the package and the pin together.

---

## ADR-015 · Static analysis is the compiler hint pass, not a SonarQube project

**Date:** 2026-11-09
**Audit finding:** SQ-01
**Status:** Applied

**Decision:** the repository does not run SonarQube or SonarCloud, and no
`sonar-project.properties` is committed. Nim findings are produced by a second,
quiet `nim check --hints:on --warnings:on` pass in `./task check`, which fails on
`XDeclaredButNotUsed`, `UnusedImport`, `ShadowIdent`, `CaseTransition` and
`UserWarning` unless `tools/archcheck/allowlist_deadcode.txt` names them. The
custom `tools/archcheck` rules and ESLint keep their existing scopes.

**Reason:** there is no Sonar server and no first-party Nim analyser. A Sonar
project without one would score the 17,102-line Nim tree at zero and report a
green TS-only quality gate as if it covered the product, which is the same
blind spot the audit found in `--hints:off`. The compiler already detects the
bug and dead-code classes that matter here; the gate only had to stop discarding
the findings.

**Reopener:** a Nim-capable analyser or a hosted Sonar instance with an external
issue import (`sonar.externalIssuesReportPaths`) is adopted. Then the compiler
pass stays as the fast local gate and Sonar becomes the dashboard, not the
oracle.


## ADR-016 · The API is a single writer, with a stated recovery time

**Date:** 2026-11-10
**Audit finding:** BE-23
**Status:** Applied

**Decision:** one API process serves every request. Its rate-limit counters
(`apps/api/src/ratelimit.nim`), WebSocket fan-out hub (`apps/api/src/live.nim`)
and config snapshot cache (`modules/platform/config/store.nim`) live in process
memory, and the deployment runs exactly one container
(`ops/systemd/majadu-api.container`, `PublishPort=127.0.0.1:8080:8080`). Running
two instances is out of scope until each of those three stores is shared, so
the operator treats the process as the single writer it is.

Recovery time is part of the decision, not an afterthought:

| Failure | Behaviour | Target |
|---|---|---|
| process crash | `Restart=on-failure`, `RestartSec=3` | API answering `/readyz` within 60 s |
| failed release | `deploy-vps.sh` restarts `:prev` and re-runs the readiness gate | back on the previous build within 60 s |
| deliberate restart | in-flight requests drain for `MAJADU_DRAIN_MS` (5000) | sockets drop, clients reconnect |
| host loss | not covered by this ADR; provider rebuild | outside the 99.0% target's assumptions |

The monthly availability target (99.0%, about 7 h 18 min) is the single-instance
target documented in `docs/ops/operations.md` §4: a host failure is downtime,
not a degraded mode, and no automatic failover is claimed.

**Reason:** the three in-memory stores are the product's cheap path. A shared
limiter would add a round trip to every request, and the hub would need
`LISTEN/NOTIFY` or a producer on `platform.outbox` (which today has none) to fan
out across processes. With one operator, one match-night load profile and a
512 MB container, that cost buys nothing the target needs; what it does need is
for the constraint to be written down, so nobody scales the container to
`--scale 2` and halves each budget while half the spectators miss a
`session.changed` event.

**Reopener:** a second instance is required (a staging parity run with two
instances, or an availability target above what one host can meet). Before that,
the limiter counters move to a shared store (PostgreSQL or Redis), the hub gains
a `LISTEN/NOTIFY` bridge or an outbox producer, and the config cache gains an
invalidation channel; the parity suite then runs against two instances with no
duplicate budget and no missed broadcast.

## ADR-017 · A skip points at a game; the court reference waits for courts to exist

**Date:** 2026-11-10
**Audit finding:** DB-11
**Status:** Applied for `session.game_skips`; Deferred for the court key

**Decision:** `0051_game_skips_game_fk.sql` adds
`game_skips_game_fk` from `session.game_skips (community_id, session_id, round_no, court_no)`
to `session.games`, on delete cascade. The court reference the finding also
asked for (`games_court_fk`, `game_skips_court_fk`) is not added.

`session.courts` has no writer in v2. The session model, the contract and the
wizard never create a court row; only the v1 import fills the table. Counted on
the local clusters the same day: bm2_dev has 288 sessions, 0 courts and 266
games, every game without a court; bm2_e2e has 10 sessions, 0 courts and 12
games, likewise. bm2_explore, which was imported from v1, has 126 courts and 0
orphans. A foreign key to `session.courts` would therefore reject the schedule
writer for every v2 session while catching nothing that exists.

**Reason:** the finding's premise is that `courts` is the register of courts.
It is, for the imported database only. The coordinate that games, sets and
skips share is real and worth enforcing, and the game is the row that owns it,
so the skip-to-game key closes the sharpest part at no cost. The court key needs
a product answer first.

**Reopener:** the wizard starts materialising courts (a session owns its court
rows, with or without a time), or `session.courts` is dropped as dead weight
from the import. Then the composite key is added in the same release.

**Update 2026-11-10 (wave 5):** `0053_court_coordinate_reference.sql` enforces
the coordinate where the court register exists, without the foreign key. A game
or a skip may only name a court the session has once the session has at least
one `session.courts` row, and a court row still used by a game cannot be deleted
or renumbered. A session with no court rows, which is every v2 session, behaves
exactly as before, so the reason for the deferral still holds. The foreign key
remains deferred, with this guard as the interim control.

## ADR-018 · Tenancy is guarded at build time, not by row level security

**Date:** 2026-11-10
**Audit finding:** DB-16
**Status:** Deferred (partial)

**Decision:** no `enable row level security` and no tenant-scoped views. The
second line of defence is the statement scan in `tools/archcheck`: every SQL
statement in `apps/`, `modules/` and `tools/` that names a domain table must
scope it by `community_id` in the same query level, or be listed in
`tools/archcheck/allowlist_community.txt` with a reason. This change extended
the scanned set from `session.`/`player.`/`rating.`/`tournament.`/`community.` to
`achievement.` as well, so badge reads are covered; the one legitimate
platform-wide statement (the badge catalogue, which has no community column)
joined the allowlist.

**Reason:** RLS needs the requesting community on every connection, and the pool
hands a request whichever connection is free per statement (`shared/platform-lib/db/db.nim`).
A `set_config` is therefore either per transaction (the read paths mostly are
not) or per statement (a rewrite of every read), and the tools that legitimately
work across communities would need a bypass role. That is a rewrite, not a
finding-sized change, and a half-applied policy would be worse than none: it
would read as a defence while leaving every unscanned path open.

**Reopener:** the read paths move behind one checkout per request (a request
context that pins the connection and sets `majadu.community_id` locally). Then
the policies can be enabled table by table, starting with `player.players`,
`session.sessions` and `rating.player_state`, and the existing scan becomes the
guard that the policy exists on every tenant table.

## ADR-019 · The deploy must run `dbtools seed`, and the config seed stays insert-only

**Date:** 2026-11-10
**Audit finding:** DB-06
**Status:** Deferred (blocked on the deploy script)

**Decision:** `db/seeds/platform_config.sql` keeps `on conflict (key) do
nothing`. A release that adds a config key must add its seed row in the same
commit; `tools/archcheck` already fails the build when a registry key has no
seed row (`boundViolations` in `tools/archcheck/scan_constants.nim`, covered by
`tools/archcheck/tests/constants_test.nim`). Running `dbtools seed` between
`migrate` and `verify` in `ops/scripts/deploy-vps.sh` is the remaining half and
belongs to the operator scripts.

**Reason:** `do update` would make the seed the authority for every value, so a
deploy would overwrite the per-platform tuning that `platform.config` exists to
hold, and the current `dbtools seed` comment promises the opposite ("operator
edits to existing values survive"). Whether the seed or the operator owns a
default is a product decision; the outage it would prevent is a missing row,
which the build already refuses.

**Reopener:** the deploy script gains the `seed` step (or the cutover runbook
is replaced by it). If the seed then runs on every release, decide explicitly
whether `do update` is wanted, and change the `dbtools seed` comment in the same
commit.
