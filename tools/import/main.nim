## One-time import from the v1 database (`bm_staging`) into v2.
##
## Run once at cutover and again if it fails halfway: every row written here has
## an entry in `import.row_map`, and a rerun reads that map instead of minting a
## second set of ids. Each stage commits on its own, so a stage that fails leaves
## the stages before it committed and a rerun resumes from the map; the source is
## only ever read. Once the cutover has completed the target is refused, because
## a rerun would write v1 names, tiers, statuses and versions over v2.
##
##   import etl    --source <v1 dsn> --target <v2 dsn> --slug majadu --name Majadu
##   import verify --source <v1 dsn> --target <v2 dsn>
##
## Domains not imported yet are printed as skipped instead of being silently
## ignored: a report that claims zero differences across the whole database
## while half of it stayed behind would be worse than no report.

import std/[json, options, os, sequtils, strutils, tables]
import db/db
import uuidv7
import platform/config/registry
import platform/config/store
import achievement/infrastructure/backfill as achievementBackfill
import rating/infrastructure/ingest as ratingIngest
import rating/infrastructure/params
import rating/infrastructure/tournament as ratingTournament

type
  Dsn* = object
    source*: string
    target*: string

  Result* = object
    created*: int
    updated*: int
    collapsed*: int
    skipped*: int

proc fail(message: string) {.noreturn.} =
  stderr.writeLine "import: " & message
  quit(2)

proc parseArgs(): tuple[command: string, dsn: Dsn, slug, name, timezone: string,
                        dryRun: bool] =
  result.command = "etl"
  if paramCount() >= 1:
    result.command = paramStr(1)
    if result.command notin ["etl", "verify"]:
      fail "unknown command " & result.command & " (etl|verify)"
  result.dsn.source = getEnv("MAJADU_ETL_SOURCE_DSN")
  result.dsn.target = getEnv("MAJADU_PG_DSN")
  result.slug = getEnv("MAJADU_IMPORT_SLUG")
  result.name = getEnv("MAJADU_IMPORT_NAME")
  result.timezone = getEnv("MAJADU_IMPORT_TIMEZONE")
  var index = 2
  while index <= paramCount():
    let flag = paramStr(index)
    let hasValue = index + 1 <= paramCount()
    case flag
    of "--source":
      if not hasValue: fail "--source needs a value"
      inc index; result.dsn.source = paramStr(index)
    of "--target":
      if not hasValue: fail "--target needs a value"
      inc index; result.dsn.target = paramStr(index)
    of "--slug":
      if not hasValue: fail "--slug needs a value"
      inc index; result.slug = paramStr(index)
    of "--name":
      if not hasValue: fail "--name needs a value"
      inc index; result.name = paramStr(index)
    of "--timezone":
      if not hasValue: fail "--timezone needs a value"
      inc index; result.timezone = paramStr(index)
    of "--dry-run":
      result.dryRun = true
    else:
      fail "unknown argument " & flag
    inc index
  if result.dsn.source.len == 0:
    fail "MAJADU_ETL_SOURCE_DSN or --source is required"
  if result.dsn.target.len == 0:
    fail "MAJADU_PG_DSN or --target is required"

proc configString(db: Db, key: string): Option[string] =
  let row = db.queryOne(
    "select value #>> '{}' as value from platform.config where key = $1",
    @[textParam(key)])
  if row.isSome: some(row.get.get("value")) else: none(string)

proc cutoverCompleted(db: Db): bool =
  ## True once v2 is the live database. The import is a migration tool, not a
  ## refresh tool: after this point the v2 rows are the source of truth.
  let row = db.queryOne(
    "select completed_at from platform.cutover_state where id")
  row.isSome and row.get["completed_at"].isSome

proc resolveCommunity(db: Db, slug, name, timezone: string,
                      dryRun: bool): string =
  ## The v1 database has no communities; the import puts everything in one. A
  ## rerun with the same slug finds it and changes nothing.
  let id = getEnv("MAJADU_IMPORT_COMMUNITY_ID")
  if id.len > 0:
    let found = db.queryOne("select id from platform.community where id = $1::uuid",
      @[textParam(id)])
    if found.isNone: fail "MAJADU_IMPORT_COMMUNITY_ID names no community"
    return found.get.get("id")
  if slug.len == 0:
    fail "--slug is required (or MAJADU_IMPORT_SLUG)"
  let existing = db.queryOne(
    "select id from platform.community where slug = $1", @[textParam(slug)])
  if existing.isSome:
    return existing.get.get("id")
  if name.len == 0:
    fail "--name is required when the community does not exist yet"
  var zone = timezone
  if zone.len == 0:
    let configured = configString(db, $keyCommunityDefaultTimezone)
    if configured.isNone:
      fail "no --timezone and community.default_timezone is not configured"
    zone = configured.get
  if dryRun:
    return "00000000-0000-0000-0000-000000000000"
  let created = db.queryOne(
    """insert into platform.community (slug, name, timezone)
       values ($1, $2, $3) returning id""",
    @[textParam(slug), textParam(name), textParam(zone)])
  created.get.get("id")

proc mapLookup(conn: DbConn, communityId, entity, oldId: string): Option[string] =
  let row = conn.queryOne(
    """select new_id::text as new_id from import.row_map
       where community_id = $1::uuid and entity = $2 and old_id = $3""",
    @[textParam(communityId), textParam(entity), textParam(oldId)])
  if row.isSome: some(row.get.get("new_id")) else: none(string)

proc mapPut(conn: DbConn, communityId, entity, oldId, newId: string) =
  discard conn.execUpdate(
    """insert into import.row_map (community_id, entity, old_id, new_id)
       values ($1::uuid, $2, $3, $4::uuid)
       on conflict (community_id, entity, old_id)
       do update set new_id = excluded.new_id""",
    @[textParam(communityId), textParam(entity), textParam(oldId),
      textParam(newId)])

proc importPlayers(source, target: Db, communityId: string, dryRun: bool): Result =
  ## `canonical_name` is unique per community in v2 but not in v1. Two v1 rows
  ## with the same name collapse into one player; the second old id is mapped to
  ## the first new id, which is what "collapsed" counts.
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for row in source.query(
      """select id::text as id, canonical_name, coalesce(tier, '') as tier,
                gender, created_at::text as created_at,
                updated_at::text as updated_at
         from bm.players order by created_at, id"""):
      let oldId = row.get("id")
      let mapped = mapLookup(conn, communityId, "player", oldId)
      if dryRun:
        inc stats.created
        continue
      if mapped.isSome:
        let present = conn.queryOne(
          "select 1 as ok from player.players where community_id = $1::uuid and id = $2::uuid",
          @[textParam(communityId), textParam(mapped.get)])
        if present.isSome:
          discard conn.execUpdate(
            """update player.players
               set canonical_name = $3, tier = nullif($4, ''), gender = $5,
                   updated_at = $6::timestamptz
               where community_id = $1::uuid and id = $2::uuid""",
            @[textParam(communityId), textParam(mapped.get),
              textParam(row.get("canonical_name")), textParam(row.get("tier")),
              textParam(row.get("gender")), textParam(row.get("updated_at"))])
          inc stats.updated
          continue
      let inserted = conn.queryOne(
        """insert into player.players
             (id, community_id, canonical_name, tier, gender, created_at, updated_at)
           values ($1::uuid, $2::uuid, $3, nullif($4, ''), $5,
                   $6::timestamptz, $7::timestamptz)
           on conflict (community_id, canonical_key) do update
             set updated_at = player.players.updated_at
           returning id::text as id""",
        @[textParam(uuidv7()), textParam(communityId),
          textParam(row.get("canonical_name")), textParam(row.get("tier")),
          textParam(row.get("gender")), textParam(row.get("created_at")),
          textParam(row.get("updated_at"))])
      let newId = inserted.get.get("id")
      if mapped.isSome and mapped.get != newId:
        inc stats.collapsed
      else:
        inc stats.created
      mapPut(conn, communityId, "player", oldId, newId)
    1)
  stats

proc importAliases(source, target: Db, communityId: string,
                   dryRun: bool): Result =
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for row in source.query(
      """select a.alias_name, a.player_id::text as player_id,
                a.created_at::text as created_at
         from bm.player_aliases a order by a.created_at, a.alias_name"""):
      let player = mapLookup(conn, communityId, "player", row.get("player_id"))
      if player.isNone:
        inc stats.skipped
        continue
      if dryRun:
        inc stats.created
        continue
      let changed = conn.execUpdate(
        """insert into player.aliases (community_id, player_id, alias, created_at)
           values ($1::uuid, $2::uuid, $3, $4::timestamptz)
           on conflict (community_id, alias_key) do nothing""",
        @[textParam(communityId), textParam(player.get), textParam(row.get("alias_name")),
          textParam(row.get("created_at"))])
      if changed == 1: inc stats.created else: inc stats.updated
    1)
  stats

proc v2Source(v1Source: string): string =
  ## v2 knows three origins: a hand-made session, the generator, and a snapshot
  ## that arrived from elsewhere. v1 split the last one into `compat_publish`
  ## and `legacy_snapshot`; both describe imported data.
  if v1Source == "manual": "manual" else: "legacy_snapshot"

proc timezoneOf*(db: Db, communityId: string): string =
  let row = db.queryOne(
    "select timezone from platform.community where id = $1::uuid",
    @[textParam(communityId)])
  if row.isNone: fail "community " & communityId & " does not exist"
  row.get.get("timezone")

proc calendarDate*(db: Db, instant, timezone: string): string =
  ## A v1 timestamp is an instant; the community's calendar date is the day that
  ## instant falls on *there*. 23:30 WIB is the same day in Jakarta and the next
  ## day in UTC, so this conversion cannot be skipped.
  let row = db.queryOne(
    "select ($1::timestamptz at time zone $2)::date::text as day",
    @[textParam(instant), textParam(timezone)])
  row.get.get("day")

proc importSessions(source, target: Db, communityId: string,
                    dryRun: bool): Result =
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for row in source.query(
      """select s.id::text as id, s.title,
                s.session_date::text as session_date,
                s.session_start::text as start_time, s.slot_minutes, s.status,
                s.source, s.created_at::text as created_at,
                s.updated_at::text as updated_at,
                exists (
                  select 1 from bm.rating_sources r
                  where r.source_id = s.share_code or r.source_id = s.id::text
                ) as rated
         from bm.sessions s order by s.session_date, s.created_at, s.id"""):
      let oldId = row.get("id")
      # v1 recorded no approval timestamp; `updated_at` is the closest thing to
      # the moment a session left draft. More importantly, v1 only rated the
      # sessions its rating pipeline saw, and seven early sessions were locked
      # before it existed. `approved_at` is the rating gate in v2, so those
      # sessions stay unapproved here: otherwise they would earn points that
      # production never awarded.
      let approvedAt =
        if row.get("status") == "draft" or row.get("rated") != "t": ""
        else: row.get("updated_at")
      if dryRun:
        inc stats.created
        continue
      let mapped = mapLookup(conn, communityId, "session", oldId)
      var newId = ""
      if mapped.isSome:
        newId = mapped.get
        discard conn.execUpdate(
          """update session.sessions
             set title = $3, session_date = $4::date, start_time = $5::time,
                 slot_minutes = $6::int, status = $7, source = $8,
                 approved_at = nullif($9, '')::timestamptz,
                 created_at = $10::timestamptz, updated_at = $11::timestamptz
             where community_id = $1::uuid and id = $2::uuid""",
          @[textParam(communityId), textParam(newId), textParam(row.get("title")),
            textParam(row.get("session_date")), textParam(row.get("start_time")),
            textParam(row.get("slot_minutes")), textParam(row.get("status")),
            textParam(v2Source(row.get("source"))), textParam(approvedAt),
            textParam(row.get("created_at")), textParam(row.get("updated_at"))])
        inc stats.updated
      else:
        newId = uuidv7()
        discard conn.execUpdate(
          """insert into session.sessions
               (id, community_id, title, session_date, start_time, slot_minutes,
                status, source, approved_at, created_at, updated_at)
             values ($1::uuid, $2::uuid, $3, $4::date, $5::time, $6::int,
                     $7, $8, nullif($9, '')::timestamptz,
                     $10::timestamptz, $11::timestamptz)""",
          @[textParam(newId), textParam(communityId), textParam(row.get("title")),
            textParam(row.get("session_date")), textParam(row.get("start_time")),
            textParam(row.get("slot_minutes")), textParam(row.get("status")),
            textParam(v2Source(row.get("source"))), textParam(approvedAt),
            textParam(row.get("created_at")), textParam(row.get("updated_at"))])
        inc stats.created
      mapPut(conn, communityId, "session", oldId, newId)
    1)
  stats

proc importCourts(source, target: Db, communityId: string,
                  dryRun: bool): Result =
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for row in source.query(
      """select internal_id::text as id, session_id::text as session_id,
                court_index, court_name, start_time::text as start_time,
                end_time::text as end_time
         from bm.session_courts order by session_id, court_index"""):
      let session = mapLookup(conn, communityId, "session", row.get("session_id"))
      if session.isNone:
        inc stats.skipped
        continue
      if dryRun:
        inc stats.created
        continue
      let mapped = mapLookup(conn, communityId, "court", row.get("id"))
      let newId = if mapped.isSome: mapped.get else: uuidv7()
      discard conn.execUpdate(
        """insert into session.courts
             (id, community_id, session_id, court_index, court_name,
              start_time, end_time)
           values ($1::uuid, $2::uuid, $3::uuid, $4::int, $5, $6::time, $7::time)
           on conflict (session_id, court_index) do update
             set court_name = excluded.court_name,
                 start_time = excluded.start_time,
                 end_time = excluded.end_time""",
        @[textParam(newId), textParam(communityId), textParam(session.get),
          textParam(row.get("court_index")), textParam(row.get("court_name")),
          textParam(row.get("start_time")), textParam(row.get("end_time"))])
      mapPut(conn, communityId, "court", row.get("id"), newId)
      if mapped.isSome: inc stats.updated else: inc stats.created
    1)
  stats

proc importParticipants(source, target: Db, communityId: string,
                        dryRun: bool): Result =
  ## A v1 participant may be a placeholder with no `player_id`; v2 participants
  ## are real players, so those rows are counted as skipped rather than turned
  ## into somebody. The games that named them keep an empty side.
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for row in source.query(
      """select internal_id::text as id, session_id::text as session_id,
                coalesce(player_id::text, '') as player_id, is_absent
         from bm.session_players order by session_id, sort_order, internal_id"""):
      let session = mapLookup(conn, communityId, "session", row.get("session_id"))
      if session.isNone:
        inc stats.skipped
        continue
      if row.get("player_id").len == 0:
        inc stats.skipped
        continue
      let player = mapLookup(conn, communityId, "player", row.get("player_id"))
      if player.isNone:
        inc stats.skipped
        continue
      if dryRun:
        inc stats.created
        continue
      let existing = mapLookup(conn, communityId, "participant", row.get("id"))
      if existing.isSome:
        # The same v1 row was imported before, so this is an update, not a new
        # participant. The absent flag only ever moves from false to true.
        discard conn.execUpdate(
          """update session.participants set is_absent = is_absent or $3::boolean
             where community_id = $1::uuid and id = $2::uuid""",
          @[textParam(communityId), textParam(existing.get),
            textParam(if row.get("is_absent") == "t": "true" else: "false")])
        mapPut(conn, communityId, "participant", row.get("id"), existing.get)
        inc stats.updated
        continue
      var participantId = ""
      let inserted = conn.queryOne(
        """insert into session.participants
             (community_id, session_id, player_id, is_absent)
           values ($1::uuid, $2::uuid, $3::uuid, $4::boolean)
           on conflict (session_id, player_id) do nothing
           returning id::text as id""",
        @[textParam(communityId), textParam(session.get), textParam(player.get),
          textParam(if row.get("is_absent") == "t": "true" else: "false")])
      if inserted.isSome:
        participantId = inserted.get.get("id")
        inc stats.created
      else:
        # v1 could list the same player under two refs; v2 has one participant
        # per (session, player), so the second old id points at the first row.
        let present = conn.queryOne(
          """select id::text as id from session.participants
             where session_id = $1::uuid and player_id = $2::uuid""",
          @[textParam(session.get), textParam(player.get)])
        participantId = present.get.get("id")
        discard conn.execUpdate(
          """update session.participants set is_absent = is_absent or $3::boolean
             where community_id = $1::uuid and id = $2::uuid""",
          @[textParam(communityId), textParam(participantId),
            textParam(if row.get("is_absent") == "t": "true" else: "false")])
        inc stats.collapsed
      mapPut(conn, communityId, "participant", row.get("id"), participantId)
    1)
  stats

proc importGames(source, target: Db, communityId: string,
                 dryRun: bool): Result =
  ## v1 keeps the sides in `scheduled_game_players`, one row per slot; v2 keeps
  ## four columns on the game itself. The slot is the position, so the side is
  ## `side_a1`, `side_a2`, `side_b1` or `side_b2`.
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for sessionRow in source.query(
      "select id::text as id from bm.sessions order by session_date, id"):
      let oldSessionId = sessionRow.get("id")
      let session = mapLookup(conn, communityId, "session", oldSessionId)
      if session.isNone:
        continue
      # Old participant id -> old player id, so a game slot resolves in memory
      # instead of joining across two databases.
      var participantPlayer = initTable[string, string]()
      var refPlayer = initTable[string, string]()
      for row in source.query(
        """select internal_id::text as id, player_ref,
                  coalesce(player_id::text, '') as player_id
           from bm.session_players where session_id = $1::uuid""",
        @[textParam(oldSessionId)]):
        participantPlayer[row.get("id")] = row.get("player_id")
        refPlayer[row.get("player_ref")] = row.get("player_id")

      var sides = initTable[string, array[4, string]]()
      for row in source.query(
        """select scheduled_game_internal_id::text as game_id, team, position,
                  session_player_internal_id::text as participant_id
           from bm.scheduled_game_players gp
           join bm.scheduled_games g
             on g.internal_id = gp.scheduled_game_internal_id
           where g.session_id = $1::uuid""",
        @[textParam(oldSessionId)]):
        let gameId = row.get("game_id")
        if not sides.hasKey(gameId): sides[gameId] = ["", "", "", ""]
        let slot = if row.get("team") == "A": 0 else: 2
        let position = parseInt(row.get("position"))
        if position >= 0 and position <= 1:
          sides[gameId][slot + position] = participantPlayer.getOrDefault(
            row.get("participant_id"))

      for row in source.query(
        """select internal_id::text as id, slot_index, court_index, status,
                  is_played, coalesce(score_a, -1) as score_a,
                  coalesce(score_b, -1) as score_b, created_at::text as created_at,
                  updated_at::text as updated_at,
                  coalesce(array_to_string(skipped_player_refs, ','), '')
                    as skipped_refs
           from bm.scheduled_games where session_id = $1::uuid
           order by slot_index, court_index""",
        @[textParam(oldSessionId)]):
        let oldId = row.get("id")
        # v1 stored the flag and the status separately; v2 has only the status.
        var status = row.get("status")
        if status != "cancelled" and row.get("is_played") == "t":
          status = "played"
        if dryRun:
          inc stats.created
          continue
        var values: array[4, string]
        if sides.hasKey(oldId): values = sides[oldId]
        var playerIds: array[4, string]
        var unresolved = false
        for index in 0 ..< 4:
          if values[index].len == 0: continue
          let mapped = mapLookup(conn, communityId, "player", values[index])
          if mapped.isNone:
            unresolved = true
            continue
          playerIds[index] = mapped.get
        if unresolved: inc stats.skipped
        let mapped = mapLookup(conn, communityId, "game", oldId)
        let newId = if mapped.isSome: mapped.get else: uuidv7()
        discard conn.execUpdate(
          """insert into session.games
               (id, community_id, session_id, round_no, court_no, score_a,
                score_b, status, created_at, updated_at,
                side_a1, side_a2, side_b1, side_b2)
             values ($1::uuid, $2::uuid, $3::uuid, $4::int, $5::int,
                     nullif($6, -1)::int, nullif($7, -1)::int, $8,
                     $9::timestamptz, $10::timestamptz,
                     nullif($11, '')::uuid, nullif($12, '')::uuid,
                     nullif($13, '')::uuid, nullif($14, '')::uuid)
             on conflict (session_id, round_no, court_no) do update
               set score_a = excluded.score_a, score_b = excluded.score_b,
                   status = excluded.status, side_a1 = excluded.side_a1,
                   side_a2 = excluded.side_a2, side_b1 = excluded.side_b1,
                   side_b2 = excluded.side_b2, updated_at = excluded.updated_at""",
          @[textParam(newId), textParam(communityId), textParam(session.get),
            textParam(row.get("slot_index")), textParam(row.get("court_index")),
            textParam(row.get("score_a")), textParam(row.get("score_b")),
            textParam(status), textParam(row.get("created_at")),
            textParam(row.get("updated_at")),
            textParam(playerIds[0]), textParam(playerIds[1]),
            textParam(playerIds[2]), textParam(playerIds[3])])
        mapPut(conn, communityId, "game", oldId, newId)
        if mapped.isSome: inc stats.updated else: inc stats.created
        # Per-player skip: v1 kept short player refs on the game, v2 keeps one
        # row per skipped player. Rewrite the set so a rerun stays idempotent.
        discard conn.execUpdate(
          """delete from session.game_skips
             where community_id = $1::uuid and session_id = $2::uuid
               and round_no = $3 and court_no = $4""",
          @[textParam(communityId), textParam(session.get),
            textParam(row.get("slot_index")), textParam(row.get("court_index"))])
        let skippedRefs = row.get("skipped_refs")
        if skippedRefs.len > 0:
          for playerRef in skippedRefs.split(','):
            let oldPlayer = refPlayer.getOrDefault(playerRef)
            if oldPlayer.len == 0: continue
            let mappedPlayer = mapLookup(conn, communityId, "player", oldPlayer)
            if mappedPlayer.isNone:
              inc stats.skipped
              continue
            discard conn.execUpdate(
              """insert into session.game_skips
                   (community_id, session_id, round_no, court_no, player_id)
                 values ($1::uuid, $2::uuid, $3, $4, $5::uuid)
                 on conflict do nothing""",
              @[textParam(communityId), textParam(session.get),
                textParam(row.get("slot_index")), textParam(row.get("court_index")),
                textParam(mappedPlayer.get)])
    1)
  stats

const classicRounds = {"group": 0, "qf": 1, "sf": 2, "3rd": 3, "final": 4}.toTable

proc tournamentStatus(source: Db, oldId, format: string): string =
  ## v1 had no status column: a tournament was whatever its matches said. A
  ## bracket with no score is still being played, one with every score is done,
  ## and one with no rows at all was never started.
  let counts =
    if format == "team":
      source.queryOne(
        """select count(*)::int as total,
                  count(g.score_a)::int as scored
           from bm.tournament_team_match_games g
           join bm.tournament_team_matches m on m.id = g.team_match_id
           where m.tournament_id = $1::uuid""", @[textParam(oldId)])
    else:
      source.queryOne(
        """select count(*)::int as total, count(score_a)::int as scored
           from bm.tournament_matches where tournament_id = $1::uuid""",
        @[textParam(oldId)])
  let total = parseInt(counts.get.get("total"))
  let scored = parseInt(counts.get.get("scored"))
  if total == 0: "draft"
  elif scored == total: "completed"
  else: "active"

proc importTournamentHeaders(source, target: Db, communityId: string,
                             dryRun: bool): Result =
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for row in source.query(
      """select id::text as id, share_code, name, event_date::text as event_date,
                format, version, created_at::text as created_at,
                updated_at::text as updated_at
         from bm.tournaments order by event_date, created_at, id"""):
      let oldId = row.get("id")
      let status = tournamentStatus(source, oldId, row.get("format"))
      if dryRun:
        inc stats.created
        continue
      let mapped = mapLookup(conn, communityId, "tournament", oldId)
      var newId = ""
      if mapped.isSome:
        newId = mapped.get
        discard conn.execUpdate(
          """update tournament.tournaments
             set name = $3, event_date = $4::date, format = $5, status = $6,
                 version = $7::int, created_at = $8::timestamptz,
                 updated_at = $9::timestamptz
             where community_id = $1::uuid and id = $2::uuid""",
          @[textParam(communityId), textParam(newId), textParam(row.get("name")),
            textParam(row.get("event_date")), textParam(row.get("format")),
            textParam(status), textParam(row.get("version")),
            textParam(row.get("created_at")), textParam(row.get("updated_at"))])
        inc stats.updated
      else:
        newId = uuidv7()
        discard conn.execUpdate(
          """insert into tournament.tournaments
               (id, community_id, name, event_date, format, status, version,
                created_at, updated_at)
             values ($1::uuid, $2::uuid, $3, $4::date, $5, $6, $7::int,
                     $8::timestamptz, $9::timestamptz)""",
          @[textParam(newId), textParam(communityId), textParam(row.get("name")),
            textParam(row.get("event_date")), textParam(row.get("format")),
            textParam(status), textParam(row.get("version")),
            textParam(row.get("created_at")), textParam(row.get("updated_at"))])
        inc stats.created
      mapPut(conn, communityId, "tournament", oldId, newId)
      # The share code is how a v1 rating source named a tournament, so mapping
      # it lets the source resolve without a second lookup table.
      mapPut(conn, communityId, "tournament_code", row.get("share_code"), newId)
    1)
  stats

proc importClassicChildren(source: Db, conn: DbConn, communityId,
                           oldTournamentId, newTournamentId: string,
                           dryRun: bool, stats: var Result) =
  ## Pairs, groups and matches. A pair whose two v1 players could not both be
  ## mapped cannot exist in v2 (both columns are required and distinct), so it
  ## is counted and the matches that named it keep an empty side.
  var pairIds = initTable[string, string]()
  for row in source.query(
    """select id::text as id, pair_name, seed from bm.tournament_pairs
       where tournament_id = $1::uuid order by seed, id""",
    @[textParam(oldTournamentId)]):
    var players: seq[string] = @[]
    for entry in source.query(
      """select player_id::text as player_id from bm.tournament_pair_players
         where pair_id = $1::uuid order by player_id""", @[textParam(row.get("id"))]):
      let mapped = mapLookup(conn, communityId, "player", entry.get("player_id"))
      if mapped.isSome and mapped.get notin players:
        players.add(mapped.get)
    if players.len != 2:
      inc stats.skipped
      continue
    if dryRun:
      inc stats.created
      continue
    let mapped = mapLookup(conn, communityId, "pair", row.get("id"))
    let pairId = if mapped.isSome: mapped.get else: uuidv7()
    discard conn.execUpdate(
      """insert into tournament.pairs
           (id, community_id, tournament_id, display_name, player_a_id, player_b_id)
         values ($1::uuid, $2::uuid, $3::uuid, $4, $5::uuid, $6::uuid)
         on conflict (community_id, id) do update
           set display_name = excluded.display_name,
               player_a_id = excluded.player_a_id,
               player_b_id = excluded.player_b_id""",
      @[textParam(pairId), textParam(communityId), textParam(newTournamentId),
        textParam(row.get("pair_name")), textParam(players[0]),
        textParam(players[1])])
    mapPut(conn, communityId, "pair", row.get("id"), pairId)
    pairIds[row.get("id")] = pairId
    if mapped.isSome: inc stats.updated else: inc stats.created

  # v2 stores the group slot as 0..3 (groups_position_check). v1 rows are 1..4 in
  # production but 0-based in the synthetic fixture, so the slot is normalised
  # against the group minimum instead of assuming one convention.
  for row in source.query(
    """select group_id, pair_id::text as pair_id,
              position - min(position) over (partition by group_id) as position
       from bm.tournament_groups where tournament_id = $1::uuid""",
    @[textParam(oldTournamentId)]):
    let pairId = pairIds.getOrDefault(row.get("pair_id"))
    if pairId.len == 0 or dryRun: continue
    let present = conn.queryOne(
      """select 1 as ok from tournament.groups
         where tournament_id = $1::uuid and group_id = $2 and position = $3::int""",
      @[textParam(newTournamentId), textParam(row.get("group_id")),
        textParam(row.get("position"))])
    discard conn.execUpdate(
      """insert into tournament.groups
           (community_id, tournament_id, group_id, pair_id, position)
         values ($1::uuid, $2::uuid, $3, $4::uuid, $5::int)
         on conflict (tournament_id, group_id, position) do update
           set pair_id = excluded.pair_id""",
      @[textParam(communityId), textParam(newTournamentId),
        textParam(row.get("group_id")), textParam(pairId),
        textParam(row.get("position"))])
    if present.isSome: inc stats.updated else: inc stats.created

  for row in source.query(
    """select m.id::text as id, m.phase, coalesce(m.group_id, '') as group_id,
              coalesce(m.pair_a_id::text, '') as pair_a_id,
              coalesce(m.pair_b_id::text, '') as pair_b_id,
              coalesce(m.score_a, -1) as score_a, coalesce(m.score_b, -1) as score_b,
              m.match_order, m.match_key, coalesce(p.canonical_name, '') as pic
       from bm.tournament_matches m
       left join bm.players p on p.id = m.pic_player_id
       where m.tournament_id = $1::uuid order by m.match_order, m.match_key""",
    @[textParam(oldTournamentId)]):
    if dryRun:
      inc stats.created
      continue
    let pairA = pairIds.getOrDefault(row.get("pair_a_id"))
    let pairB = pairIds.getOrDefault(row.get("pair_b_id"))
    let mapped = mapLookup(conn, communityId, "match", row.get("id"))
    let matchId = if mapped.isSome: mapped.get else: uuidv7()
    discard conn.execUpdate(
      """insert into tournament.matches
           (id, community_id, tournament_id, round_no, pair_a_id, pair_b_id,
            score_a, score_b, status, phase, group_id, pic_name, match_key,
            match_order)
         values ($1::uuid, $2::uuid, $3::uuid, $4::int, nullif($5, '')::uuid,
                 nullif($6, '')::uuid, nullif($7, -1)::int, nullif($8, -1)::int,
                 $9, $10, nullif($11, '')::text, $12, $13, $14::int)
         on conflict (community_id, tournament_id, match_key) do update
           set round_no = excluded.round_no, pair_a_id = excluded.pair_a_id,
               pair_b_id = excluded.pair_b_id, score_a = excluded.score_a,
               score_b = excluded.score_b, status = excluded.status,
               phase = excluded.phase, group_id = excluded.group_id,
               pic_name = excluded.pic_name, match_order = excluded.match_order""",
      @[textParam(matchId), textParam(communityId), textParam(newTournamentId),
        textParam($classicRounds[row.get("phase")]), textParam(pairA),
        textParam(pairB), textParam(row.get("score_a")),
        textParam(row.get("score_b")),
        textParam(if row.get("score_a") == "-1": "scheduled" else: "played"),
        textParam(row.get("phase")), textParam(row.get("group_id")),
        textParam(row.get("pic")), textParam(row.get("match_key")),
        textParam(row.get("match_order"))])
    mapPut(conn, communityId, "match", row.get("id"), matchId)
    if mapped.isSome: inc stats.updated else: inc stats.created

proc importTeamChildren(source: Db, conn: DbConn, communityId, oldTournamentId,
                        newTournamentId: string, dryRun: bool,
                        stats: var Result) =
  var teamIds = initTable[string, string]()
  for row in source.query(
    """select id::text as id, seed, team_name from bm.tournament_teams
       where tournament_id = $1::uuid order by seed""",
    @[textParam(oldTournamentId)]):
    if dryRun:
      inc stats.created
      continue
    let mapped = mapLookup(conn, communityId, "team", row.get("id"))
    let teamId = if mapped.isSome: mapped.get else: uuidv7()
    discard conn.execUpdate(
      """insert into tournament.teams
           (id, community_id, tournament_id, seed, team_name)
         values ($1::uuid, $2::uuid, $3::uuid, $4::int, $5)
         on conflict (community_id, id) do update
           set seed = excluded.seed, team_name = excluded.team_name""",
      @[textParam(teamId), textParam(communityId), textParam(newTournamentId),
        textParam(row.get("seed")), textParam(row.get("team_name"))])
    mapPut(conn, communityId, "team", row.get("id"), teamId)
    teamIds[row.get("id")] = teamId
    if mapped.isSome: inc stats.updated else: inc stats.created

  for row in source.query(
    """select p.id::text as id, p.team_id::text as team_id, p.player_name,
              p.cls, coalesce(p.player_id::text, '') as player_id
       from bm.tournament_team_players p
       join bm.tournament_teams t on t.id = p.team_id
       where t.tournament_id = $1::uuid order by p.team_id, p.cls""",
    @[textParam(oldTournamentId)]):
    let teamId = teamIds.getOrDefault(row.get("team_id"))
    if teamId.len == 0: continue
    if dryRun:
      inc stats.created
      continue
    let existing = mapLookup(conn, communityId, "team_player", row.get("id"))
    let teamPlayerId = if existing.isSome: existing.get else: uuidv7()
    var playerId = ""
    if row.get("player_id").len > 0:
      playerId = mapLookup(conn, communityId, "player", row.get("player_id")).get("")
    # The roster is names plus classes; a name v1 never linked to a player stays
    # unlinked, because inventing a player would change the roster.
    discard conn.execUpdate(
      """insert into tournament.team_players
           (id, community_id, team_id, player_name, player_id, cls)
         values ($1::uuid, $2::uuid, $3::uuid, $4, nullif($5, '')::uuid, $6)
         on conflict (team_id, cls) do update
           set player_name = excluded.player_name,
               player_id = excluded.player_id""",
      @[textParam(teamPlayerId), textParam(communityId), textParam(teamId),
        textParam(row.get("player_name")), textParam(playerId),
        textParam(row.get("cls"))])
    mapPut(conn, communityId, "team_player", row.get("id"), teamPlayerId)
    if existing.isSome: inc stats.updated else: inc stats.created

  for row in source.query(
    """select m.id::text as id, m.phase, m.match_order, m.match_key,
              coalesce(m.team_a_id::text, '') as team_a_id,
              coalesce(m.team_b_id::text, '') as team_b_id,
              coalesce(m.courts::text, '{}') as courts
       from bm.tournament_team_matches m
       where m.tournament_id = $1::uuid order by m.match_order, m.match_key""",
    @[textParam(oldTournamentId)]):
    if dryRun:
      inc stats.created
      continue
    let teamA = teamIds.getOrDefault(row.get("team_a_id"))
    let teamB = teamIds.getOrDefault(row.get("team_b_id"))
    let mapped = mapLookup(conn, communityId, "team_match", row.get("id"))
    let matchId = if mapped.isSome: mapped.get else: uuidv7()
    discard conn.execUpdate(
      """insert into tournament.team_matches
           (id, community_id, tournament_id, phase, match_order, match_key,
            team_a_id, team_b_id, courts)
         values ($1::uuid, $2::uuid, $3::uuid, $4, $5::int, $6,
                 nullif($7, '')::uuid, nullif($8, '')::uuid, $9::text[])
         on conflict (community_id, tournament_id, match_key) do update
           set phase = excluded.phase, match_order = excluded.match_order,
               team_a_id = excluded.team_a_id, team_b_id = excluded.team_b_id,
               courts = excluded.courts""",
      @[textParam(matchId), textParam(communityId), textParam(newTournamentId),
        textParam(row.get("phase")), textParam(row.get("match_order")),
        textParam(row.get("match_key")), textParam(teamA), textParam(teamB),
        textParam(row.get("courts"))])
    mapPut(conn, communityId, "team_match", row.get("id"), matchId)
    if mapped.isSome: inc stats.updated else: inc stats.created

    for game in source.query(
      """select id::text as id, partai_index, coalesce(score_a, -1) as score_a,
                coalesce(score_b, -1) as score_b
         from bm.tournament_team_match_games
         where team_match_id = $1::uuid order by partai_index""",
      @[textParam(row.get("id"))]):
      if dryRun: continue
      let partaiMapped = mapLookup(conn, communityId, "partai", game.get("id"))
      let partaiId = if partaiMapped.isSome: partaiMapped.get else: uuidv7()
      discard conn.execUpdate(
        """insert into tournament.team_partai
             (id, community_id, team_match_id, partai_index, score_a, score_b)
           values ($1::uuid, $2::uuid, $3::uuid, $4::int,
                   nullif($5, -1)::int, nullif($6, -1)::int)
           on conflict (team_match_id, partai_index) do update
             set score_a = excluded.score_a, score_b = excluded.score_b""",
        @[textParam(partaiId), textParam(communityId), textParam(matchId),
          textParam(game.get("partai_index")), textParam(game.get("score_a")),
          textParam(game.get("score_b"))])
      mapPut(conn, communityId, "partai", game.get("id"), partaiId)
      if partaiMapped.isSome: inc stats.updated else: inc stats.created

proc importTournamentChildren(source, target: Db, communityId: string,
                              dryRun: bool): Result =
  var stats = Result()
  var rows: seq[Row] = @[]
  for row in source.query(
    "select id::text as id, format from bm.tournaments order by event_date, id"):
    rows.add(row)
  discard target.tx(proc(conn: DbConn): int =
    for row in rows:
      let newId = mapLookup(conn, communityId, "tournament", row.get("id"))
      if newId.isNone: continue
      if row.get("format") == "team":
        importTeamChildren(source, conn, communityId, row.get("id"), newId.get,
          dryRun, stats)
      else:
        importClassicChildren(source, conn, communityId, row.get("id"),
          newId.get, dryRun, stats)
    1)
  stats

proc communitySettings(db: Db, communityId: string): JsonNode =
  let row = db.queryOne(
    """select values::text as values from community.settings
       where community_id = $1::uuid""", @[textParam(communityId)])
  if row.isSome: parseJson(row.get.get("values")) else: newJObject()

proc sourceToken(v1SourceId: string): (string, string) =
  ## v1 wrote the source id as the share code and the kind in a separate column;
  ## some dumps carry a `session:` prefix. Both forms name the same row.
  for prefix in ["session:", "tournament_classic:", "tournament_team:"]:
    if v1SourceId.startsWith(prefix):
      return (v1SourceId[prefix.len .. ^1], prefix[0 ..< prefix.len - 1])
  (v1SourceId, "")

proc importRatingSources*(source, target: Db, communityId: string,
                          dryRun: bool): Result =
  ## The ledger itself is not copied: v1 stored outcomes without point values, so
  ## its numbers cannot be turned into v2 deltas. What is copied is the sign-off,
  ## and v2 then recomputes the events from the sessions it just imported.
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for row in source.query(
      """select source_id, source_kind, finalized, ingested_at::text as ingested_at
         from bm.rating_sources order by source_id"""):
      let (token, prefixKind) = sourceToken(row.get("source_id"))
      let kind = if row.get("source_kind") == "session": "session" else: "tournament"
      var newSource: Option[string]
      if kind == "session":
        let old = source.queryOne(
          """select id::text as id from bm.sessions
             where share_code = $1 or id::text = $1""", @[textParam(token)])
        if old.isSome:
          newSource = mapLookup(conn, communityId, "session", old.get.get("id"))
      else:
        newSource = mapLookup(conn, communityId, "tournament", token)
        if newSource.isNone:
          newSource = mapLookup(conn, communityId, "tournament_code", token)
      if newSource.isNone:
        inc stats.skipped
        continue
      if dryRun:
        inc stats.created
        continue
      let present = conn.queryOne(
        """select 1 as ok from rating.sources
           where community_id = $1::uuid and source_id = $2::uuid""",
        @[textParam(communityId), textParam(newSource.get)])
      discard conn.execUpdate(
        """insert into rating.sources
             (community_id, source_id, kind, finalized, finalized_at, created_at)
           values ($1::uuid, $2::uuid, $3, $4::boolean, $5::timestamptz,
                   $6::timestamptz)
           on conflict (community_id, source_id) do update
             set kind = excluded.kind, finalized = excluded.finalized,
                 finalized_at = excluded.finalized_at""",
        @[textParam(communityId), textParam(newSource.get), textParam(kind),
          textParam(if row.get("finalized") == "t": "true" else: "false"),
          textParam(if row.get("finalized") == "t": row.get("ingested_at") else: ""),
          textParam(row.get("ingested_at"))])
      if present.isSome: inc stats.updated else: inc stats.created
    1)
  stats

proc importRatingLevels*(source, target: Db, communityId: string,
                         dryRun: bool): Result =
  ## v1 kept the tournament ladder in a table: the champion's points per
  ## format and the ratio of every place. The board multiplies the two, so the
  ## ladder is copied row for row instead of being folded into deltas.
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for row in source.query(
      """select kind, champion_points::text as champion,
                coalesce(round_ratios::text, '{}') as ratios, enabled
         from bm.rank_point_levels order by kind"""):
      if dryRun:
        inc stats.created
        continue
      let present = conn.queryOne(
        """select 1 as ok from rating.levels
           where community_id = $1::uuid and kind = $2""",
        @[textParam(communityId), textParam(row.get("kind"))])
      discard conn.execUpdate(
        """insert into rating.levels
             (community_id, kind, champion_points, round_ratios, enabled,
              updated_at)
           values ($1::uuid, $2, $3::numeric, $4::jsonb, $5::boolean, now())
           on conflict (community_id, kind) do update
             set champion_points = excluded.champion_points,
                 round_ratios = excluded.round_ratios,
                 enabled = excluded.enabled,
                 updated_at = now()""",
        @[textParam(communityId), textParam(row.get("kind")),
          textParam(row.get("champion")), textParam(row.get("ratios")),
          textParam(if row.get("enabled") == "t": "true" else: "false")])
      if present.isSome: inc stats.updated else: inc stats.created
    1)
  stats

proc rebuildRating*(target: Db, communityId: string): tuple[events, deltas: int] =
  ## Deterministic: the caller may run this as often as it likes. `deltas` is
  ## the number of player-game entries the replay counted, the same number the
  ## ledger used to store as rows.
  let snapshot = loadSnapshot(target)
  let params = loadRatingParams(snapshot, communitySettings(target, communityId))
  let outcome = ratingIngest.rebuild(target, communityId, params)
  (events: outcome.events, deltas: outcome.deltas)

proc ingestFinalTournaments*(target: Db, communityId: string):
    tuple[events, deltas: int] =
  ## A tournament is only ingestable once its source is signed off, which is v1's
  ## gate too. This runs after the rebuild because `rebuild` clears every event
  ## in the community and recreates only the session ones.
  let snapshot = loadSnapshot(target)
  let params = loadRatingParams(snapshot, communitySettings(target, communityId))
  for row in target.query(
    """select t.id::text as id from tournament.tournaments t
       join rating.sources s
         on s.community_id = t.community_id and s.source_id = t.id
       where t.community_id = $1::uuid and s.finalized
       order by t.event_date, t.id""",
    @[textParam(communityId)]):
    let outcome = ratingTournament.ingestTournament(target, communityId,
      row.get("id"), params)
    result.events += outcome.events
    result.deltas += outcome.deltas

proc verifyRating*(source, target: Db, communityId: string): seq[string] =
  ## The point scales differ, so the tally is what can be compared: v1 counted
  ## games, wins and losses per player, and v2 counts the same things. A
  ## difference is reported, not smoothed over, because a v1 policy the import
  ## does not reproduce is exactly what the operator needs to know.
  var oldToNew = initTable[string, string]()
  for row in target.query(
    """select old_id, new_id::text as new_id from import.row_map
       where community_id = $1::uuid and entity = 'player'""",
    @[textParam(communityId)]):
    oldToNew[row.get("old_id")] = row.get("new_id")

  var state = initTable[string, Row]()
  for row in target.query(
    """select player_id::text as player_id, games_played, wins, losses
       from rating.player_state where community_id = $1::uuid""",
    @[textParam(communityId)]):
    state[row.get("player_id")] = row

  var compared = 0
  for row in source.query(
    """select player_id::text as player_id, games_played, wins, losses
       from bm.rating_players order by player_id"""):
    let newId = oldToNew.getOrDefault(row.get("player_id"))
    if newId.len == 0:
      result.add "v1 rating row " & row.get("player_id") & " has no mapped player"
      continue
    if not state.hasKey(newId):
      # v1 kept a tally row for every player, including the ones who never
      # played; v2 only creates state for a player with a game.
      if row.get("games_played") != "0":
        result.add "player " & row.get("player_id") &
          " has v1 games but no state in v2"
      continue
    inc compared
    let ours = state[newId]
    for field in ["games_played", "wins", "losses"]:
      if ours.get(field) != row.get(field):
        result.add "player " & row.get("player_id") & " has " & field &
          " " & ours.get(field) & " in v2 but " & row.get(field) & " in v1"
  if compared == 0 and result.len == 0:
    result.add "no player has a v1 rating tally to compare"

proc importAchievements*(source, target: Db, communityId: string,
                         dryRun: bool): Result =
  ## v1 stores a statistic per ladder (`medal:games` with value 57); v2 stores
  ## one row per threshold crossed (`games:50`). The expansion is therefore
  ## derived, not copied: every threshold the stored value has passed becomes a
  ## row, with the v1 date. Event medals keep their `tournament:<id>` key and
  ## the stored name; the rank-streak badge keeps its value as the threshold.
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for row in source.query(
      """select pa.id::text as id, pa.player_id::text as player_id,
                pa.achievement_key, pa.earned_at::text as earned_at,
                coalesce(pa.value, 0) as value,
                coalesce(pa.meta::text, '{}') as meta
         from bm.player_achievements pa order by pa.earned_at, pa.id"""):
      let player = mapLookup(conn, communityId, "player", row.get("player_id"))
      if player.isNone:
        inc stats.skipped
        continue
      let key = row.get("achievement_key")
      let earnedAt = row.get("earned_at")
      if key.startsWith("tournament:"):
        if dryRun:
          inc stats.created
          continue
        let changed = conn.execUpdate(
          """insert into achievement.earned
               (community_id, player_id, achievement_key, earned_at, meta)
             values ($1::uuid, $2::uuid, $3, $4::timestamptz, $5::jsonb)
             on conflict (community_id, player_id, achievement_key) do nothing""",
          @[textParam(communityId), textParam(player.get), textParam(key),
            textParam(earnedAt), textParam(row.get("meta"))])
        if changed == 1: inc stats.created else: inc stats.updated
        continue
      if key == "medal:rank_streak":
        if dryRun:
          inc stats.created
          continue
        let changed = conn.execUpdate(
          """insert into achievement.earned
               (community_id, player_id, achievement_key, earned_at)
             values ($1::uuid, $2::uuid, $3, $4::timestamptz)
             on conflict (community_id, player_id, achievement_key) do nothing""",
          @[textParam(communityId), textParam(player.get),
            textParam("rank_streak:" & row.get("value")), textParam(earnedAt)])
        if changed == 1: inc stats.created else: inc stats.updated
        continue
      if not key.startsWith("medal:"):
        inc stats.skipped
        continue
      let unit = key["medal:".len .. ^1]
      let value = parseInt(row.get("value"))
      var awarded = 0
      # `conn`, not `target`: the pool has one connection and it is inside this
      # transaction, so asking the pool again would wait for itself.
      for definition in conn.query(
        """select key, threshold from achievement.definitions
           where key like $1 order by threshold""",
        @[textParam(unit & ":%")]):
        let threshold = parseInt(definition.get("threshold"))
        # A rank ladder counts down: #4 has earned #10 and #5, not #3.
        let passed =
          if unit == "rank": value > 0 and threshold >= value
          else: threshold <= value
        if not passed: continue
        inc awarded
        if dryRun:
          inc stats.created
          continue
        let changed = conn.execUpdate(
          """insert into achievement.earned
               (community_id, player_id, achievement_key, earned_at)
             values ($1::uuid, $2::uuid, $3, $4::timestamptz)
             on conflict (community_id, player_id, achievement_key) do nothing""",
          @[textParam(communityId), textParam(player.get),
            textParam(definition.get("key")), textParam(row.get("earned_at"))])
        if changed == 1: inc stats.created else: inc stats.updated
      if awarded == 0:
        inc stats.skipped
    1)
  stats

proc backfillAchievements*(target: Db, communityId: string): Result =
  ## Adds whatever the imported games qualify for and v1 did not record. v1
  ## rows are written first and this uses `do nothing`, so a v1 date survives.
  let outcome = achievementBackfill.backfill(target, communityId)
  Result(created: outcome.awarded, updated: outcome.players)

proc verifyAchievements*(source, target: Db, communityId: string): seq[string] =
  ## Every threshold v1 implies must exist in v2. The reverse is not required:
  ## v2 also awards what the imported games crossed even when v1 never stored it.
  var oldToNew = initTable[string, string]()
  for row in target.query(
    """select old_id, new_id::text as new_id from import.row_map
       where community_id = $1::uuid and entity = 'player'""",
    @[textParam(communityId)]):
    oldToNew[row.get("old_id")] = row.get("new_id")
  var definitions = initTable[string, seq[int]]()
  for row in target.query(
    "select key, threshold from achievement.definitions order by threshold"):
    let key = row.get("key")
    let unit = key[0 ..< key.find(':')]
    definitions.mgetOrPut(unit, @[]).add(parseInt(row.get("threshold")))

  var checked = 0
  for row in source.query(
    """select player_id::text as player_id, achievement_key,
              coalesce(value, 0) as value
       from bm.player_achievements"""):
    let key = row.get("achievement_key")
    if not key.startsWith("medal:"): continue
    let unit = key["medal:".len .. ^1]
    if not definitions.hasKey(unit): continue
    let newId = oldToNew.getOrDefault(row.get("player_id"))
    if newId.len == 0:
      result.add "v1 achievement player " & row.get("player_id") & " has no mapping"
      continue
    let value = parseInt(row.get("value"))
    if unit == "rank_streak":
      # v1 kept one row carrying the best run; the rungs only shape its shelf.
      inc checked
      let found = target.queryOne(
        """select 1 as ok from achievement.earned
           where community_id = $1::uuid and player_id = $2::uuid
             and achievement_key = $3""",
        @[textParam(communityId), textParam(newId),
          textParam("rank_streak:" & $value)])
      if found.isNone:
        result.add "player " & row.get("player_id") & " is missing " &
          "rank_streak:" & $value & " in v2"
      continue
    for threshold in definitions[unit]:
      let passed =
        if unit == "rank": value > 0 and threshold >= value
        else: threshold <= value
      if not passed: continue
      inc checked
      let found = target.queryOne(
        """select 1 as ok from achievement.earned
           where community_id = $1::uuid and player_id = $2::uuid
             and achievement_key = $3""",
        @[textParam(communityId), textParam(newId),
          textParam(unit & ":" & $threshold)])
      if found.isNone:
        result.add "player " & row.get("player_id") & " is missing " &
          unit & ":" & $threshold & " in v2"
  if checked == 0 and result.len == 0:
    result.add "no achievement has been imported into this community"

proc importSnapshots(source, target: Db, communityId: string,
                     dryRun: bool): Result =
  ## v1 took one snapshot per capture date; the board's movement arrow reads
  ## the most recent snapshot older than its anchor. The stored number is the
  ## points total, which is what v2's `rating.snapshots.rating` carries.
  var stats = Result()
  discard target.tx(proc(conn: DbConn): int =
    for row in source.query(
      """select as_of::text as as_of, player_id::text as player_id,
                points::int as points
         from bm.rank_snapshots order by as_of, player_id"""):
      let player = mapLookup(conn, communityId, "player", row.get("player_id"))
      if player.isNone:
        inc stats.skipped
        continue
      if dryRun:
        inc stats.created
        continue
      let existed = conn.queryOne(
        """select 1 as ok from rating.snapshots
           where community_id = $1::uuid and player_id = $2::uuid
             and taken_on = $3::date""",
        @[textParam(communityId), textParam(player.get),
          textParam(row.get("as_of"))])
      discard conn.execUpdate(
        """insert into rating.snapshots
             (community_id, player_id, taken_on, rating)
           values ($1::uuid, $2::uuid, $3::date, $4::int)
           on conflict (community_id, player_id, taken_on) do update
             set rating = excluded.rating""",
        @[textParam(communityId), textParam(player.get),
          textParam(row.get("as_of")), intParam(parseInt(row.get("points")))])
      if existed.isSome: inc stats.updated else: inc stats.created
    1)
  stats

proc verifySnapshots(source, target: Db, communityId: string): seq[string] =
  var mapped, missing, different = 0
  for row in source.query(
    """select as_of::text as as_of, player_id::text as player_id,
              points::int as points
       from bm.rank_snapshots"""):
    let player = target.queryOne(
      """select new_id::text as new_id from import.row_map
         where community_id = $1::uuid and entity = 'player' and old_id = $2""",
      @[textParam(communityId), textParam(row.get("player_id"))])
    if player.isNone:
      continue
    inc mapped
    let found = target.queryOne(
      """select rating::text as rating from rating.snapshots
         where community_id = $1::uuid and player_id = $2::uuid
           and taken_on = $3::date""",
      @[textParam(communityId), textParam(player.get.get("new_id")),
        textParam(row.get("as_of"))])
    if found.isNone:
      inc missing
    elif parseInt(found.get.get("rating")) != parseInt(row.get("points")):
      inc different
  if missing + different > 0:
    result.add "snapshots: " & $missing & " missing, " & $different &
      " with different points"
  elif mapped == 0:
    result.add "no rank snapshot has been imported into this community"

proc importEtl*(source, target: Db, slug, name, timezone: string,
                dryRun: bool): tuple[players, aliases, sessions, courts,
                                     participants, games: Result] =
  if not dryRun and getEnv("MAJADU_IMPORT_ALLOW_POST_CUTOVER") != "1" and
      cutoverCompleted(target):
    fail "the cutover has completed; a run would overwrite v2 rows with v1 " &
      "values. Set MAJADU_IMPORT_ALLOW_POST_CUTOVER=1 if that is intended."
  let communityId = resolveCommunity(target, slug, name, timezone, dryRun)
  let players = importPlayers(source, target, communityId, dryRun)
  let aliases = importAliases(source, target, communityId, dryRun)
  # Sessions before anything that points at them, and participants before games
  # because the side columns are foreign keys into the participant set.
  let sessions = importSessions(source, target, communityId, dryRun)
  let courts = importCourts(source, target, communityId, dryRun)
  let participants = importParticipants(source, target, communityId, dryRun)
  let games = importGames(source, target, communityId, dryRun)
  let tournaments = importTournamentHeaders(source, target, communityId, dryRun)
  let tournamentChildren = importTournamentChildren(source, target, communityId,
    dryRun)
  # The sign-off is v1 data; the numbers are recomputed from the rows above, so
  # the ledger v2 serves is produced by v2's own formula.
  let sources = importRatingSources(source, target, communityId, dryRun)
  let levels = importRatingLevels(source, target, communityId, dryRun)
  var rebuilt = (events: 0, deltas: 0)
  var tournamentRating = (events: 0, deltas: 0)
  if not dryRun:
    rebuilt = rebuildRating(target, communityId)
    tournamentRating = ingestFinalTournaments(target, communityId)
  # v1 badges first, then the v2 backfill: the backfill does not overwrite an
  # existing row, so a v1 date survives and only new crossings are added.
  let achievements = importAchievements(source, target, communityId, dryRun)
  let snapshots = importSnapshots(source, target, communityId, dryRun)
  var awarded = Result()
  if not dryRun:
    awarded = backfillAchievements(target, communityId)
  result = (players: players, aliases: aliases, sessions: sessions,
            courts: courts, participants: participants, games: games)
  echo $(%*{
    "communityId": communityId,
    "dryRun": dryRun,
    "players": %*{"created": players.created, "updated": players.updated,
                  "collapsed": players.collapsed},
    "aliases": %*{"created": aliases.created, "updated": aliases.updated,
                  "skipped": aliases.skipped},
    "sessions": %*{"created": sessions.created, "updated": sessions.updated},
    "courts": %*{"created": courts.created, "updated": courts.updated,
                 "skipped": courts.skipped},
    "participants": %*{"created": participants.created,
                       "updated": participants.updated,
                       "collapsed": participants.collapsed,
                       "skipped": participants.skipped},
    "games": %*{"created": games.created, "updated": games.updated,
                "skipped": games.skipped},
    "ratingSources": %*{"created": sources.created, "updated": sources.updated,
                        "skipped": sources.skipped},
    "rating": %*{"events": rebuilt.events + tournamentRating.events,
                 "deltas": rebuilt.deltas + tournamentRating.deltas},
    "ratingLevels": %*{"created": levels.created,
                       "updated": levels.updated},
    "tournaments": %*{"created": tournaments.created,
                      "updated": tournaments.updated},
    "tournamentChildren": %*{"created": tournamentChildren.created,
                             "updated": tournamentChildren.updated,
                             "skipped": tournamentChildren.skipped},
    "achievements": %*{"created": achievements.created,
                       "updated": achievements.updated,
                       "skipped": achievements.skipped,
                       "backfilled": awarded.created},
    "snapshots": %*{"created": snapshots.created,
                    "updated": snapshots.updated,
                    "skipped": snapshots.skipped},
    "skippedDomains": %[]})

proc verifyPlayers*(source, target: Db, communityId: string): seq[string] =
  ## Compares the mapped rows field by field. Counts alone would hide a rename
  ## and would make a collapsed duplicate look like a missing row.
  var oldToNew = initTable[string, string]()
  for row in target.query(
    """select old_id, new_id::text as new_id from import.row_map
       where community_id = $1::uuid and entity = 'player'""",
    @[textParam(communityId)]):
    oldToNew[row.get("old_id")] = row.get("new_id")
  if oldToNew.len == 0:
    return @["no player has been imported into this community"]

  var byId = initTable[string, Row]()
  for row in target.query(
    """select id::text as id, canonical_name, coalesce(tier, '') as tier, gender
       from player.players where community_id = $1::uuid""",
    @[textParam(communityId)]):
    byId[row.get("id")] = row

  for row in source.query(
    """select id::text as id, canonical_name, coalesce(tier, '') as tier, gender
       from bm.players order by id"""):
    let newId = oldToNew.getOrDefault(row.get("id"))
    if newId.len == 0:
      result.add "v1 player " & row.get("id") & " has no mapping"
      continue
    if not byId.hasKey(newId):
      result.add "mapped player " & newId & " is missing from v2"
      continue
    let ours = byId[newId]
    if ours.get("canonical_name") != row.get("canonical_name"):
      result.add "name differs for v1 player " & row.get("id")
    if ours.get("tier") != row.get("tier") or ours.get("gender") != row.get("gender"):
      result.add "tier or gender differs for v1 player " & row.get("id")

proc verifyAliases*(source, target: Db, communityId: string): seq[string] =
  let mapped = target.query(
    """select old_id, new_id::text as new_id from import.row_map
       where community_id = $1::uuid and entity = 'player'""",
    @[textParam(communityId)])
  var oldToNew = initTable[string, string]()
  for row in mapped: oldToNew[row.get("old_id")] = row.get("new_id")
  for row in source.query(
    """select alias_name, player_id::text as player_id from bm.player_aliases"""):
    let newId = oldToNew.getOrDefault(row.get("player_id"))
    if newId.len == 0:
      result.add "v1 alias " & row.get("alias_name") & " has no mapped player"
      continue
    let found = target.queryOne(
      """select 1 as ok from player.aliases
         where community_id = $1::uuid and player_id = $2::uuid
           and alias_key = btrim(regexp_replace(lower($3), '\s+', ' ', 'g'))""",
      @[textParam(communityId), textParam(newId), textParam(row.get("alias_name"))])
    if found.isNone:
      result.add "alias " & row.get("alias_name") & " did not reach v2"

proc verifySessions*(source, target: Db, communityId: string): seq[string] =
  var oldToNew = initTable[string, string]()
  for row in target.query(
    """select old_id, new_id::text as new_id from import.row_map
       where community_id = $1::uuid and entity = 'session'""",
    @[textParam(communityId)]):
    oldToNew[row.get("old_id")] = row.get("new_id")
  if oldToNew.len == 0:
    return @["no session has been imported into this community"]

  var byId = initTable[string, Row]()
  for row in target.query(
    """select id::text as id, title, session_date::text as session_date,
              to_char(start_time, 'HH24:MI:SS') as start_time, slot_minutes,
              status
       from session.sessions where community_id = $1::uuid""",
    @[textParam(communityId)]):
    byId[row.get("id")] = row

  for row in source.query(
    """select id::text as id, title, session_date::text as session_date,
              session_start::text as start_time, slot_minutes, status
       from bm.sessions order by session_date, id"""):
    let newId = oldToNew.getOrDefault(row.get("id"))
    if newId.len == 0:
      result.add "v1 session " & row.get("id") & " has no mapping"
      continue
    if not byId.hasKey(newId):
      result.add "mapped session " & newId & " is missing from v2"
      continue
    let ours = byId[newId]
    if ours.get("title") != row.get("title"):
      result.add "title differs for v1 session " & row.get("id")
    if ours.get("session_date") != row.get("session_date"):
      result.add "date differs for v1 session " & row.get("id")
    if ours.get("start_time")[0 .. 4] != row.get("start_time")[0 .. 4]:
      result.add "start time differs for v1 session " & row.get("id")
    if ours.get("slot_minutes") != row.get("slot_minutes"):
      result.add "slot minutes differ for v1 session " & row.get("id")
    if ours.get("status") != row.get("status"):
      result.add "status differs for v1 session " & row.get("id")

proc sideNames(row: Row, prefix: string): seq[string] =
  for slot in ["1", "2"]:
    let key = prefix & slot
    if row.has(key) and row[key].isSome and row.get(key).len > 0:
      result.add(row.get(key))

proc verifyGames*(source, target: Db, communityId: string): seq[string] =
  ## Games are compared by round and court inside each session, as names, since
  ## the ids are new. A game that lost a side because its player was a v1
  ## placeholder is reported rather than silently accepted.
  var oldToNew = initTable[string, string]()
  for row in target.query(
    """select old_id, new_id::text as new_id from import.row_map
       where community_id = $1::uuid and entity = 'session'""",
    @[textParam(communityId)]):
    oldToNew[row.get("old_id")] = row.get("new_id")

  var checked = 0
  for sessionRow in source.query(
    "select id::text as id, share_code from bm.sessions order by session_date, id"):
    let oldSessionId = sessionRow.get("id")
    let newSessionId = oldToNew.getOrDefault(oldSessionId)
    if newSessionId.len == 0:
      result.add "v1 session " & oldSessionId & " has no mapping"
      continue

    var expected = initTable[string, Row]()
    for row in source.query(
      """select g.slot_index || '-' || g.court_index as key,
                g.status, g.is_played, g.score_a, g.score_b,
                coalesce(a.canonical_name, '') as a0,
                coalesce(b.canonical_name, '') as a1,
                coalesce(c.canonical_name, '') as b0,
                coalesce(d.canonical_name, '') as b1
         from bm.scheduled_games g
         left join bm.session_players pa on pa.internal_id = (
           select gp.session_player_internal_id from bm.scheduled_game_players gp
           where gp.scheduled_game_internal_id = g.internal_id
             and gp.team = 'A' and gp.position = 0)
         left join bm.players a on a.id = pa.player_id
         left join bm.session_players pb on pb.internal_id = (
           select gp.session_player_internal_id from bm.scheduled_game_players gp
           where gp.scheduled_game_internal_id = g.internal_id
             and gp.team = 'A' and gp.position = 1)
         left join bm.players b on b.id = pb.player_id
         left join bm.session_players pc on pc.internal_id = (
           select gp.session_player_internal_id from bm.scheduled_game_players gp
           where gp.scheduled_game_internal_id = g.internal_id
             and gp.team = 'B' and gp.position = 0)
         left join bm.players c on c.id = pc.player_id
         left join bm.session_players pd on pd.internal_id = (
           select gp.session_player_internal_id from bm.scheduled_game_players gp
           where gp.scheduled_game_internal_id = g.internal_id
             and gp.team = 'B' and gp.position = 1)
         left join bm.players d on d.id = pd.player_id
         where g.session_id = $1::uuid""",
      @[textParam(oldSessionId)]):
      expected[row.get("key")] = row

    var actual = initTable[string, Row]()
    for row in target.query(
      """select g.round_no || '-' || g.court_no as key, g.status, g.score_a,
                g.score_b,
                coalesce(a1.canonical_name, '') as a1,
                coalesce(a2.canonical_name, '') as a2,
                coalesce(b1.canonical_name, '') as b1,
                coalesce(b2.canonical_name, '') as b2
         from session.games g
         left join player.players a1 on a1.id = g.side_a1
         left join player.players a2 on a2.id = g.side_a2
         left join player.players b1 on b1.id = g.side_b1
         left join player.players b2 on b2.id = g.side_b2
         where g.community_id = $1::uuid and g.session_id = $2::uuid""",
      @[textParam(communityId), textParam(newSessionId)]):
      actual[row.get("key")] = row

    if expected.len != actual.len:
      result.add "session " & sessionRow.get("share_code") & " has " &
        $actual.len & " games in v2 but " & $expected.len & " in v1"
    for key, source1 in expected:
      if not actual.hasKey(key):
        result.add "session " & sessionRow.get("share_code") &
          " is missing game " & key
        continue
      let ours = actual[key]
      inc checked
      var wantStatus = source1.get("status")
      if wantStatus != "cancelled" and source1.get("is_played") == "t":
        wantStatus = "played"
      if ours.get("status") != wantStatus:
        result.add "game " & key & " of session " & sessionRow.get("share_code") &
          " has status " & ours.get("status") & ", v1 says " & wantStatus
      for slot in ["score_a", "score_b"]:
        if ours[slot].isNone != source1[slot].isNone or
           (ours[slot].isSome and ours.get(slot) != source1.get(slot)):
          result.add "game " & key & " of session " &
            sessionRow.get("share_code") & " has a different " & slot
      let wantA = @[source1.get("a0"), source1.get("a1")].filterIt(it.len > 0)
      let wantB = @[source1.get("b0"), source1.get("b1")].filterIt(it.len > 0)
      if ours.sideNames("a") != wantA or ours.sideNames("b") != wantB:
        result.add "game " & key & " of session " &
          sessionRow.get("share_code") & " has different players"
  if checked == 0 and result.len == 0:
    result.add "no game has been imported into this community"

proc verifyTournaments*(source, target: Db, communityId: string): seq[string] =
  ## Classic tournaments are compared match by match through their stable match
  ## key, with the pair sides as names; team tournaments through their seeds and
  ## partai scores. A missing row is reported, not skipped.
  var oldToNew = initTable[string, string]()
  for row in target.query(
    """select old_id, new_id::text as new_id from import.row_map
       where community_id = $1::uuid and entity = 'tournament'""",
    @[textParam(communityId)]):
    oldToNew[row.get("old_id")] = row.get("new_id")
  if oldToNew.len == 0:
    return @["no tournament has been imported into this community"]

  var checked = 0
  for row in source.query(
    """select id::text as id, share_code, name, event_date::text as event_date,
              format, version
       from bm.tournaments order by event_date, id"""):
    let newId = oldToNew.getOrDefault(row.get("id"))
    if newId.len == 0:
      result.add "v1 tournament " & row.get("id") & " has no mapping"
      continue
    let header = target.queryOne(
      """select name, event_date::text as event_date, format, version
         from tournament.tournaments
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(newId)])
    if header.isNone:
      result.add "mapped tournament " & newId & " is missing from v2"
      continue
    let ours = header.get
    for field in ["name", "event_date", "format", "version"]:
      if ours.get(field) != row.get(field):
        result.add "tournament " & row.get("share_code") & " has a different " & field

    if row.get("format") == "team":
      var teams = initTable[string, string]()
      for entry in target.query(
        """select seed, team_name from tournament.teams
           where community_id = $1::uuid and tournament_id = $2::uuid""",
        @[textParam(communityId), textParam(newId)]):
        teams[entry.get("seed")] = entry.get("team_name")
      for entry in source.query(
        """select seed, team_name from bm.tournament_teams
           where tournament_id = $1::uuid order by seed""",
        @[textParam(row.get("id"))]):
        if teams.getOrDefault(entry.get("seed")) != entry.get("team_name"):
          result.add "tournament " & row.get("share_code") & " team seed " &
            entry.get("seed") & " differs"
      for entry in source.query(
        """select t.team_name, p.cls, p.player_name
           from bm.tournament_team_players p
           join bm.tournament_teams t on t.id = p.team_id
           where t.tournament_id = $1::uuid order by t.seed, p.cls""",
        @[textParam(row.get("id"))]):
        let roster = target.queryOne(
          """select tp.player_name
             from tournament.team_players tp
             join tournament.teams t on t.id = tp.team_id
             where t.community_id = $1::uuid and t.tournament_id = $2::uuid
               and t.team_name = $3 and tp.cls = $4""",
          @[textParam(communityId), textParam(newId), textParam(entry.get("team_name")),
            textParam(entry.get("cls"))])
        inc checked
        if roster.isNone or roster.get.get("player_name") != entry.get("player_name"):
          result.add "tournament " & row.get("share_code") & " roster " &
            entry.get("team_name") & " " & entry.get("cls") & " differs"
      for entry in source.query(
        """select m.match_key, g.partai_index, coalesce(g.score_a, -1) as score_a,
                  coalesce(g.score_b, -1) as score_b
           from bm.tournament_team_match_games g
           join bm.tournament_team_matches m on m.id = g.team_match_id
           where m.tournament_id = $1::uuid""",
        @[textParam(row.get("id"))]):
        let partai = target.queryOne(
          """select coalesce(p.score_a, -1) as score_a, coalesce(p.score_b, -1) as score_b
             from tournament.team_partai p
             join tournament.team_matches m on m.id = p.team_match_id
             where m.community_id = $1::uuid and m.tournament_id = $2::uuid
               and m.match_key = $3 and p.partai_index = $4::int""",
          @[textParam(communityId), textParam(newId), textParam(entry.get("match_key")),
            textParam(entry.get("partai_index"))])
        inc checked
        if partai.isNone or partai.get.get("score_a") != entry.get("score_a") or
           partai.get.get("score_b") != entry.get("score_b"):
          result.add "tournament " & row.get("share_code") & " partai " &
            entry.get("match_key") & "-" & entry.get("partai_index") & " differs"
      continue

    var expected = initTable[string, Row]()
    for entry in source.query(
      """select m.match_key, m.phase, coalesce(m.score_a, -1) as score_a,
                coalesce(m.score_b, -1) as score_b,
                coalesce(pa.pair_name, '') as pair_a,
                coalesce(pb.pair_name, '') as pair_b
         from bm.tournament_matches m
         left join bm.tournament_pairs pa on pa.id = m.pair_a_id
         left join bm.tournament_pairs pb on pb.id = m.pair_b_id
         where m.tournament_id = $1::uuid""",
      @[textParam(row.get("id"))]):
      expected[entry.get("match_key")] = entry
    var actual = initTable[string, Row]()
    for entry in target.query(
      """select m.match_key, m.phase, coalesce(m.score_a, -1) as score_a,
                coalesce(m.score_b, -1) as score_b,
                coalesce(m.pair_a_id::text, '') as pair_a_id,
                coalesce(m.pair_b_id::text, '') as pair_b_id
         from tournament.matches m
         where m.community_id = $1::uuid and m.tournament_id = $2::uuid""",
      @[textParam(communityId), textParam(newId)]):
      actual[entry.get("match_key")] = entry
    if expected.len != actual.len:
      result.add "tournament " & row.get("share_code") & " has " & $actual.len &
        " matches in v2 but " & $expected.len & " in v1"
    for key, source1 in expected:
      if not actual.hasKey(key):
        result.add "tournament " & row.get("share_code") & " is missing match " & key
        continue
      let ours2 = actual[key]
      inc checked
      for field in ["phase", "score_a", "score_b"]:
        if ours2.get(field) != source1.get(field):
          result.add "match " & key & " of " & row.get("share_code") &
            " has a different " & field
      for side in ["a", "b"]:
        let want = source1.get("pair_" & side)
        let pairId = ours2.get("pair_" & side & "_id")
        var got = ""
        if pairId.len > 0:
          let pair = target.queryOne(
            """select display_name from tournament.pairs
               where community_id = $1::uuid and id = $2::uuid""",
            @[textParam(communityId), textParam(pairId)])
          if pair.isSome: got = pair.get.get("display_name")
        if want != got:
          result.add "match " & key & " of " & row.get("share_code") &
            " has a different pair " & side
  if checked == 0 and result.len == 0:
    result.add "no tournament row has been imported into this community"

proc verifyEtl(source, target: Db, slugArg: string) =
  let communityId = getEnv("MAJADU_IMPORT_COMMUNITY_ID")
  var resolved = communityId
  if resolved.len == 0:
    let slug = if slugArg.len > 0: slugArg else: getEnv("MAJADU_IMPORT_SLUG")
    if slug.len == 0:
      fail "verify needs MAJADU_IMPORT_SLUG or MAJADU_IMPORT_COMMUNITY_ID"
    let row = target.queryOne(
      "select id::text as id from platform.community where slug = $1",
      @[textParam(slug)])
    if row.isNone: fail "community " & slug & " does not exist"
    resolved = row.get.get("id")

  var problems = verifyPlayers(source, target, resolved)
  problems.add verifyAliases(source, target, resolved)
  problems.add verifySessions(source, target, resolved)
  problems.add verifyGames(source, target, resolved)
  problems.add verifyRating(source, target, resolved)
  problems.add verifyTournaments(source, target, resolved)
  problems.add verifyAchievements(source, target, resolved)
  problems.add verifySnapshots(source, target, resolved)
  if problems.len > 0:
    for problem in problems:
      stderr.writeLine "import: " & problem
    echo $(%*{"communityId": resolved, "problems": problems.len})
    quit(1)
  echo $(%*{"communityId": resolved, "problems": 0,
            "checkedDomains": %["players", "aliases", "sessions", "games",
                                "rating", "tournaments", "achievements",
                                "snapshots"]})

proc main() =
  let args = parseArgs()
  let source = openDb(args.dsn.source, 1)
  defer: source.close()
  let target = openDb(args.dsn.target, 1)
  defer: target.close()
  case args.command
  of "etl":
    discard importEtl(source, target, args.slug, args.name, args.timezone,
      args.dryRun)
  of "verify":
    verifyEtl(source, target, args.slug)
  else:
    fail "unknown command " & args.command

when isMainModule:
  main()
