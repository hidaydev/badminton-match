import std/[json, options, strutils]
import db/db
import ./scoring
import ./lifecycle
import skips

type
  Side* = object
    ## Up to two players per side; an empty slot is a position, not a player.
    first*: string
    second*: string

  GameSpec* = object
    round*: int
    court*: int
    sideA*: Side
    sideB*: Side

  ScheduleStatus* = enum
    ssOk = "ok"
    ssNotFound = "not_found"
    ssStale = "stale"
    ssInvalid = "invalid"
    ssInvalidSequence = "invalid_sequence"
    ssHasSets = "has_sets"
    ssUnknownPlayer = "unknown_player"
    ssNotParticipant = "not_participant"
    ssLocked = "locked"

proc parseGameKey*(key: string): Option[(int, int)] =
  ## The contract calls a game `{round}-{court}`, the same pair the unique index
  ## uses, so a key never needs a lookup table.
  let parts = key.split('-')
  if parts.len != 2 or parts[0].len == 0 or parts[1].len == 0:
    return none((int, int))
  try:
    some((parseInt(parts[0]), parseInt(parts[1])))
  except ValueError:
    none((int, int))

proc parseSide(node: JsonNode): Side =
  if node.kind != JArray or node.len > 2:
    raise newException(ValueError, "a side takes at most two players")
  for entry in node:
    if entry.kind != JString:
      raise newException(ValueError, "side entries must be player ids")
  if node.len > 0: result.first = node[0].getStr()
  if node.len > 1: result.second = node[1].getStr()

proc parseSchedule*(body: JsonNode): seq[GameSpec] =
  if body.kind != JObject or not body.hasKey("games") or
     body["games"].kind != JArray:
    raise newException(ValueError, "body must contain a games array")
  var seen: seq[string] = @[]
  for entry in body["games"]:
    if entry.kind != JObject:
      raise newException(ValueError, "each game must be an object")
    var game = GameSpec()
    game.round = entry["round"].getInt()
    game.court = entry["court"].getInt()
    if game.round < 0 or game.court < 0:
      raise newException(ValueError, "round and court cannot be negative")
    if entry.hasKey("sideA"): game.sideA = parseSide(entry["sideA"])
    if entry.hasKey("sideB"): game.sideB = parseSide(entry["sideB"])
    let slot = $game.round & "-" & $game.court
    if slot in seen:
      raise newException(ValueError, "duplicate game " & slot)
    seen.add(slot)
    let players = @[game.sideA.first, game.sideA.second,
      game.sideB.first, game.sideB.second]
    for index in 0 ..< players.len:
      for other in index + 1 ..< players.len:
        if players[index].len > 0 and players[index] == players[other]:
          raise newException(ValueError, "a player cannot stand twice in one game")
    result.add(game)

proc parsePlayerIds*(body: JsonNode): seq[string] =
  if body.kind != JObject or not body.hasKey("playerIds") or
     body["playerIds"].kind != JArray:
    raise newException(ValueError, "body must contain a playerIds array")
  for entry in body["playerIds"]:
    if entry.kind != JString:
      raise newException(ValueError, "playerIds must be strings")
    result.add(entry.getStr())

proc sessionVersion(db: Db, communityId, sessionId: string): Option[int] =
  let row = db.queryOne(
    """select version from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)])
  if row.isSome: some(parseInt(row.get.get("version"))) else: none(int)

proc classify(db: Db, communityId, sessionId: string,
              expectedVersion: int): ScheduleStatus =
  ## Only called after a guarded write matched nothing.
  let version = sessionVersion(db, communityId, sessionId)
  if version.isNone: ssNotFound
  elif version.get != expectedVersion: ssStale
  else: ssStale

proc gate(conn: DbConn, communityId, sessionId: string,
          expectedVersion: int): ScheduleStatus =
  ## One predicate for every write: a session edits only while it is a draft.
  ## Locking approves and rates it, so a change after that has to unlock first,
  ## which also withdraws what the session contributed to the board.
  let row = conn.queryOne(
    """select version, status from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)])
  if row.isNone:
    return ssNotFound
  if parseInt(row.get.get("version")) != expectedVersion:
    return ssStale
  if not isEditable(row.get.get("status")):
    return ssLocked
  ssOk

proc gameExists(conn: DbConn, communityId, sessionId: string,
                key: (int, int)): bool =
  conn.queryOne(
    """select 1 as ok from session.games
       where community_id = $1::uuid and session_id = $2::uuid
         and round_no = $3 and court_no = $4""",
    @[textParam(communityId), textParam(sessionId),
      intParam(key[0].int64), intParam(key[1].int64)]).isSome

proc bump(conn: DbConn, communityId, sessionId: string,
          expectedVersion: int): bool =
  conn.execUpdate(
    """update session.sessions set version = version + 1, updated_at = now()
       where community_id = $1::uuid and id = $2::uuid and version = $3""",
    @[textParam(communityId), textParam(sessionId),
      intParam(expectedVersion.int64)]) == 1

proc countKnownPlayers(db: Db, communityId: string,
                       playerIds: seq[string]): int =
  ## Counts how many of the given players exist in this community.
  if playerIds.len == 0:
    return 0
  let row = db.queryOne(
    """select count(*)::int as found from player.players
       where community_id = $1::uuid and id = any($2::uuid[])""",
    @[textParam(communityId),
      textParam("{" & playerIds.join(",") & "}")])
  parseInt(row.get.get("found"))

proc unknownParticipants(conn: DbConn, communityId, sessionId: string,
                         playerIds: seq[string]): bool =
  ## A player who exists in the community but is not in this session cannot be
  ## marked absent: the write would bump the version and change nothing.
  if playerIds.len == 0:
    return false
  conn.queryOne(
    """select 1 as missing from unnest($1::uuid[]) as wanted(id)
       where not exists (
         select 1 from session.participants p
         where p.community_id = $2::uuid and p.session_id = $3::uuid
           and p.player_id = wanted.id)
       limit 1""",
    @[textParam("{" & playerIds.join(",") & "}"), textParam(communityId),
      textParam(sessionId)]).isSome

proc putSchedule*(db: Db, communityId, sessionId: string, expectedVersion: int,
                  games: seq[GameSpec]): ScheduleStatus =
  ## Replaces the teams of the named games and registers every referenced player
  ## as a participant. Games not named in the payload keep their row, so a
  ## partially filled schedule is a valid state.
  var playerIds: seq[string] = @[]
  for game in games:
    for playerId in [game.sideA.first, game.sideA.second,
                     game.sideB.first, game.sideB.second]:
      if playerId.len > 0 and playerId notin playerIds:
        playerIds.add(playerId)
  if countKnownPlayers(db, communityId, playerIds) != playerIds.len:
    return ssUnknownPlayer

  var outcome = ssOk
  try:
    discard db.tx(proc(conn: DbConn): int =
      let allowed = gate(conn, communityId, sessionId, expectedVersion)
      if allowed != ssOk:
        outcome = allowed
        return 0
      if not bump(conn, communityId, sessionId, expectedVersion):
        outcome = ssStale
        return 0
      for playerId in playerIds:
        discard conn.execUpdate(
          """insert into session.participants (community_id, session_id, player_id)
             values ($1::uuid, $2::uuid, $3::uuid)
             on conflict (session_id, player_id) do nothing""",
          @[textParam(communityId), textParam(sessionId), textParam(playerId)])
      for game in games:
        discard conn.execUpdate(
          """insert into session.games
               (community_id, session_id, round_no, court_no,
                side_a1, side_a2, side_b1, side_b2)
             values ($1::uuid, $2::uuid, $3, $4,
                     nullif($5, '')::uuid, nullif($6, '')::uuid,
                     nullif($7, '')::uuid, nullif($8, '')::uuid)
             on conflict (session_id, round_no, court_no) do update set
               side_a1 = excluded.side_a1, side_a2 = excluded.side_a2,
               side_b1 = excluded.side_b1, side_b2 = excluded.side_b2""",
          @[textParam(communityId), textParam(sessionId),
            intParam(game.round.int64), intParam(game.court.int64),
            textParam(game.sideA.first), textParam(game.sideA.second),
            textParam(game.sideB.first), textParam(game.sideB.second)])
      # Rewriting the sides can orphan a skip that named a player who is no
      # longer in that game.
      discard clearStaleSkips(conn, communityId, sessionId)
      1)
  except DbError as error:
    if error.sqlState.len >= 2 and error.sqlState[0 .. 1] == "23":
      return ssInvalid
    raise
  outcome

proc setAbsent*(db: Db, communityId, sessionId: string, expectedVersion: int,
                playerIds: seq[string]): ScheduleStatus =
  ## Absent is a per-session flag, not a deletion: the game history still names
  ## the player, and rating ingest skips absent participants.
  var unique: seq[string] = @[]
  for playerId in playerIds:
    if playerId notin unique:
      unique.add(playerId)
  if countKnownPlayers(db, communityId, unique) != unique.len:
    return ssUnknownPlayer
  var outcome = ssOk
  discard db.tx(proc(conn: DbConn): int =
    let allowed = gate(conn, communityId, sessionId, expectedVersion)
    if allowed != ssOk:
      outcome = allowed
      return 0
    if unknownParticipants(conn, communityId, sessionId, unique):
      outcome = ssNotParticipant
      return 0
    if not bump(conn, communityId, sessionId, expectedVersion):
      outcome = ssStale
      return 0
    discard conn.execUpdate(
      """update session.participants set is_absent = false
         where community_id = $1::uuid and session_id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)])
    for playerId in unique:
      discard conn.execUpdate(
        """update session.participants set is_absent = true
           where community_id = $1::uuid and session_id = $2::uuid
             and player_id = $3::uuid""",
        @[textParam(communityId), textParam(sessionId), textParam(playerId)])
    1)
  outcome

proc sessionRules*(db: Db, communityId, sessionId: string): Option[ScoringRules] =
  ## The frozen rules of one session. Used by the score route to build a precise
  ## message before the write; `setSets` reads them again inside the transaction.
  let row = db.queryOne(
    """select scoring_rules from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)])
  if row.isNone:
    return none(ScoringRules)
  some(parseSnapshotNode(parseJson(row.get.get("scoring_rules"))))

proc setSets*(db: Db, communityId, sessionId, gameKey: string,
              expectedVersion: int, sets: seq[SetScore]): ScheduleStatus =
  ## Replaces the whole set list of one match. The status follows the format:
  ## `played` once one side reaches `gamesToWin`, `scheduled` while partial.
  ## An empty list clears the score.
  let key = parseGameKey(gameKey)
  if key.isNone:
    return ssInvalid
  var outcome = ssOk
  discard db.tx(proc(conn: DbConn): int =
    if not gameExists(conn, communityId, sessionId, key.get):
      outcome = ssNotFound
      return 0
    let allowed = gate(conn, communityId, sessionId, expectedVersion)
    if allowed != ssOk:
      outcome = allowed
      return 0
    let rulesRow = conn.queryOne(
      """select scoring_rules from session.sessions
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(sessionId)])
    if rulesRow.isNone:
      outcome = ssNotFound
      return 0
    let rules = parseSnapshotNode(parseJson(rulesRow.get.get("scoring_rules")))
    let verdict = validateSets(rules, sets)
    if verdict.error != seOk:
      outcome =
        if verdict.error in {seTooManySets, seSetAfterEnd}: ssInvalidSequence
        else: ssInvalid
      return 0
    if not bump(conn, communityId, sessionId, expectedVersion):
      outcome = ssStale
      return 0
    discard conn.execUpdate(
      """delete from session.game_sets
         where community_id = $1::uuid and session_id = $2::uuid
           and round_no = $3 and court_no = $4""",
      @[textParam(communityId), textParam(sessionId),
        intParam(key.get[0].int64), intParam(key.get[1].int64)])
    for index, entry in sets:
      discard conn.execUpdate(
        """insert into session.game_sets
             (community_id, session_id, round_no, court_no, set_no,
              score_a, score_b)
           values ($1::uuid, $2::uuid, $3, $4, $5, $6, $7)""",
        @[textParam(communityId), textParam(sessionId),
          intParam(key.get[0].int64), intParam(key.get[1].int64),
          intParam((index + 1).int64), intParam(entry.a.int64),
          intParam(entry.b.int64)])
    let status = if matchComplete(rules, sets): "played" else: "scheduled"
    discard conn.execUpdate(
      """update session.games
         set status = $3, score_a = null, score_b = null
         where community_id = $1::uuid and session_id = $2::uuid
           and round_no = $4 and court_no = $5""",
      @[textParam(communityId), textParam(sessionId), textParam(status),
        intParam(key.get[0].int64), intParam(key.get[1].int64)])
    1)
  outcome

proc setScore*(db: Db, communityId, sessionId, gameKey: string,
               expectedVersion, scoreA, scoreB: int): ScheduleStatus =
  ## The flat body stays for single-set sessions; it is one set.
  if scoreA < 0 or scoreA > 99 or scoreB < 0 or scoreB > 99 or scoreA == scoreB:
    return ssInvalid
  setSets(db, communityId, sessionId, gameKey, expectedVersion,
    @[SetScore(a: scoreA, b: scoreB)])

proc setPlayed*(db: Db, communityId, sessionId, gameKey: string,
                expectedVersion: int, played: bool): ScheduleStatus =
  ## v1 kept a played flag apart from the score: a host can mark a game played
  ## before entering the score. The status carries it; scores stay cleared.
  let key = parseGameKey(gameKey)
  if key.isNone:
    return ssInvalid
  var outcome = ssOk
  discard db.tx(proc(conn: DbConn): int =
    if not gameExists(conn, communityId, sessionId, key.get):
      outcome = ssNotFound
      return 0
    let allowed = gate(conn, communityId, sessionId, expectedVersion)
    if allowed != ssOk:
      outcome = allowed
      return 0
    if played and conn.queryOne(
        """select 1 as ok from session.game_sets
           where community_id = $1::uuid and session_id = $2::uuid
             and round_no = $3 and court_no = $4 limit 1""",
        @[textParam(communityId), textParam(sessionId),
          intParam(key.get[0].int64), intParam(key.get[1].int64)]).isSome:
      # Marking a scored match played would erase the sets. Clearing it first is
      # an explicit choice, not a side effect of one click.
      outcome = ssHasSets
      return 0
    if not bump(conn, communityId, sessionId, expectedVersion):
      outcome = ssStale
      return 0
    discard conn.execUpdate(
      """delete from session.game_sets
         where community_id = $1::uuid and session_id = $2::uuid
           and round_no = $3 and court_no = $4""",
      @[textParam(communityId), textParam(sessionId),
        intParam(key.get[0].int64), intParam(key.get[1].int64)])
    let status = if played: "played" else: "scheduled"
    let updated = conn.execUpdate(
      """update session.games
         set status = $3, score_a = null, score_b = null
         where community_id = $1::uuid and session_id = $2::uuid
           and round_no = $4 and court_no = $5""",
      @[textParam(communityId), textParam(sessionId), textParam(status),
        intParam(key.get[0].int64), intParam(key.get[1].int64)])
    if updated == 0:
      outcome = ssNotFound
      return 0
    1)
  if outcome != ssOk: return outcome
  ssOk

proc setSkips*(db: Db, communityId, sessionId, gameKey: string,
               expectedVersion: int, playerIds: seq[string]): ScheduleStatus =
  ## Per-player skip: the game stays scheduled/played, only the named players
  ## are excluded from that game's tally. An empty list clears the skips.
  let key = parseGameKey(gameKey)
  if key.isNone:
    return ssInvalid
  var unique: seq[string] = @[]
  for playerId in playerIds:
    if playerId notin unique:
      unique.add(playerId)
  if countKnownPlayers(db, communityId, unique) != unique.len:
    return ssUnknownPlayer
  var outcome = ssOk
  discard db.tx(proc(conn: DbConn): int =
    let game = conn.queryOne(
      """select 1 as ok from session.games
         where community_id = $1::uuid and session_id = $2::uuid
           and round_no = $3 and court_no = $4""",
      @[textParam(communityId), textParam(sessionId),
        intParam(key.get[0].int64), intParam(key.get[1].int64)])
    if game.isNone:
      outcome = ssNotFound
      return 0
    for playerId in unique:
      let participant = conn.queryOne(
        """select 1 as ok from session.participants
           where community_id = $1::uuid and session_id = $2::uuid
             and player_id = $3::uuid""",
        @[textParam(communityId), textParam(sessionId), textParam(playerId)])
      if participant.isNone:
        outcome = ssNotParticipant
        return 0
    let allowed = gate(conn, communityId, sessionId, expectedVersion)
    if allowed != ssOk:
      outcome = allowed
      return 0
    if not bump(conn, communityId, sessionId, expectedVersion):
      outcome = ssStale
      return 0
    discard conn.execUpdate(
      """delete from session.game_skips
         where community_id = $1::uuid and session_id = $2::uuid
           and round_no = $3 and court_no = $4""",
      @[textParam(communityId), textParam(sessionId),
        intParam(key.get[0].int64), intParam(key.get[1].int64)])
    for playerId in unique:
      discard conn.execUpdate(
        """insert into session.game_skips
             (community_id, session_id, round_no, court_no, player_id)
           values ($1::uuid, $2::uuid, $3, $4, $5::uuid)
           on conflict do nothing""",
        @[textParam(communityId), textParam(sessionId),
          intParam(key.get[0].int64), intParam(key.get[1].int64),
          textParam(playerId)])
    discard clearStaleSkips(conn, communityId, sessionId)
    1)
  if outcome != ssOk: return outcome
  ssOk

proc skipGame*(db: Db, communityId, sessionId, gameKey: string,
               expectedVersion: int): ScheduleStatus =
  let key = parseGameKey(gameKey)
  if key.isNone:
    return ssInvalid
  var outcome = ssOk
  discard db.tx(proc(conn: DbConn): int =
    if not gameExists(conn, communityId, sessionId, key.get):
      outcome = ssNotFound
      return 0
    let allowed = gate(conn, communityId, sessionId, expectedVersion)
    if allowed != ssOk:
      outcome = allowed
      return 0
    if not bump(conn, communityId, sessionId, expectedVersion):
      outcome = ssStale
      return 0
    let updated = conn.execUpdate(
      """update session.games
         set status = 'cancelled', score_a = null, score_b = null
         where community_id = $1::uuid and session_id = $2::uuid
           and round_no = $3 and court_no = $4""",
      @[textParam(communityId), textParam(sessionId),
        intParam(key.get[0].int64), intParam(key.get[1].int64)])
    if updated == 0:
      outcome = ssNotFound
      return 0
    # A cancelled game has no result; keeping the sets would leave the results
    # view reporting a winner for a match the session cancelled.
    discard conn.execUpdate(
      """delete from session.game_sets
         where community_id = $1::uuid and session_id = $2::uuid
           and round_no = $3 and court_no = $4""",
      @[textParam(communityId), textParam(sessionId),
        intParam(key.get[0].int64), intParam(key.get[1].int64)])
    1)
  if outcome != ssOk: return outcome
  ssOk

proc listParticipants*(db: Db, communityId, sessionId: string): seq[JsonNode] =
  for row in db.query(
    """select p.id as player_id, p.canonical_name, p.tier,
              sp.is_absent
       from session.participants sp
       join player.players p on p.id = sp.player_id
       where sp.community_id = $1::uuid and sp.session_id = $2::uuid
       order by p.canonical_name""",
    @[textParam(communityId), textParam(sessionId)]):
    result.add(%*{
      "playerId": row.get("player_id"),
      "name": row.get("canonical_name"),
      "tier": if row["tier"].isNone: newJNull() else: %row.get("tier"),
      "absent": row.get("is_absent") == "t",
    })
