## Tournament snapshots on the relational schema from 0003 + 0012.
##
## The stored shape mirrors the v1 JSON contract: classic keeps pairs, the four
## groups and the 32 bracket rows, team keeps the six rosters and the team
## matches with their three partai. Row ids are uuid strings, so a snapshot that
## was loaded can be written back without losing identity. Every statement is
## scoped by community_id.

import std/[json, options, strutils, tables, times]
import db/db
import uuidv7
import player/domain/player as playerDomain
import ./domain/classic
import ./domain/team

type
  SaveStatus* = enum
    svOk = "ok"
    svNotFound = "not_found"
    svStale = "stale"
    svInvalid = "invalid"
    svLocked = "locked"

  PatchStatus* = enum
    ptOk = "ok"
    ptNotFound = "not_found"
    ptStale = "stale"
    ptInvalid = "invalid"
    ptLocked = "locked"

  Owned = object
    ## Child row ids already belonging to this tournament. A replace reuses
    ## them so a load -> replace round trip keeps the same rows. Matches are
    ## keyed by `match_key`, which is what the client sees as `id`, so they do
    ## not need reuse to stay addressable.
    pairs, teams: Table[string, bool]

const defaultCourts = ["Court 12", "Court 13", "Court 14"]

# ── JSON helpers ───────────────────────────────────────────────────────────

proc optString(node: JsonNode, key: string): Option[string] =
  ## Nim 2.4 returns a default instead of raising on a kind mismatch, so a
  ## number sent for a name silently became "". The kind is checked here: a
  ## body that does not match the schema is a 400, never a stored guess.
  if not node.hasKey(key) or node[key].kind == JNull:
    none(string)
  elif node[key].kind != JString:
    raise newException(ValueError, key & " must be a string")
  else:
    some(node[key].getStr())

proc optRef(node: JsonNode, key: string): Option[string] =
  let value = optString(node, key)
  if value.isSome and value.get.strip().len > 0: value else: none(string)

proc optInt(node: JsonNode, key: string): Option[int] =
  if not node.hasKey(key) or node[key].kind == JNull:
    none(int)
  elif node[key].kind != JInt:
    raise newException(ValueError, key & " must be an integer")
  else:
    some(node[key].getInt())

proc objectEntry(entry: JsonNode): JsonNode =
  ## A non-object inside `pairs`/`matches`/`teams`/`partai` used to hit an
  ## assertion in `hasKey` and leave the route with an empty 500.
  if entry.kind != JObject:
    raise newException(ValueError, "every list entry must be an object")
  entry

proc text(node: JsonNode, key: string): string =
  optString(node, key).get("")

proc validDate(value: string): bool =
  ## The team validator only rejects a blank date; the date column is stricter,
  ## so a malformed one must become a 400 here instead of a database error.
  if value.len != 10 or value[4] != '-' or value[7] != '-':
    return false
  try:
    parse(value, "yyyy-MM-dd", utc()).format("yyyy-MM-dd") == value
  except TimeParseError:
    false

proc probeFormat(body: JsonNode): string =
  ## Absent or unknown `format` means classic, exactly like the v1 probe.
  if body.kind == JObject and body.hasKey("format") and
     body["format"].kind == JString and body["format"].getStr() == "team":
    "team"
  else:
    "classic"

proc issuesJson(issues: seq[ClassicIssue]): JsonNode =
  result = newJArray()
  for issue in issues:
    result.add(%*{"kind": $issue.kind, "detail": issue.detail})

proc issuesJson(issues: seq[TeamIssue]): JsonNode =
  result = newJArray()
  for issue in issues:
    result.add(%*{"kind": $issue.kind, "detail": issue.detail})

proc failure(kind, detail: string): JsonNode =
  %*{"issues": [%*{"kind": kind, "detail": detail}]}

proc invalid(issues: JsonNode): JsonNode = %*{"issues": issues}

proc withId(node: JsonNode, id: string): JsonNode =
  result = node
  result["id"] = %id

# ── body parsing ───────────────────────────────────────────────────────────

proc parseClassic(body: JsonNode): ClassicTournament =
  if body.kind != JObject:
    raise newException(ValueError, "tournament body must be an object")
  result.name = text(body, "name")
  result.date = text(body, "date")
  result.version = optInt(body, "version")
  if body.hasKey("pairs") and body["pairs"].kind notin {JArray, JNull}:
    raise newException(ValueError, "pairs must be a list")
  if body.hasKey("pairs") and body["pairs"].kind == JArray:
    for raw in body["pairs"]:
      let entry = objectEntry(raw)
      result.pairs.add(Pair(id: text(entry, "id"), name: text(entry, "name")))
  if body.hasKey("groups") and body["groups"].kind notin {JObject, JNull}:
    raise newException(ValueError, "groups must be an object keyed by group id")
  if body.hasKey("groups") and body["groups"].kind == JObject:
    for groupId in GroupIds:
      let key = $groupId
      if body["groups"].hasKey(key):
        if body["groups"][key].kind != JArray:
          raise newException(ValueError, "each group must be a list of pair ids")
        for pairId in body["groups"][key]:
          if pairId.kind != JString:
            raise newException(ValueError, "pair ids must be strings")
          result.groups[ord(groupId)].add(pairId.getStr())
  if body.hasKey("matches") and body["matches"].kind notin {JArray, JNull}:
    raise newException(ValueError, "matches must be a list")
  if body.hasKey("matches") and body["matches"].kind == JArray:
    for raw in body["matches"]:
      let entry = objectEntry(raw)
      let group = optRef(entry, "groupId")
      let phase = parseEnum[ClassicPhase](text(entry, "phase"))
      result.matches.add(ClassicMatch(
        id: text(entry, "id"),
        phase: phase,
        groupId: if group.isSome: some(parseEnum[GroupId](group.get)) else: none(GroupId),
        pairAId: optRef(entry, "pairAId"),
        pairBId: optRef(entry, "pairBId"),
        scoreA: optInt(entry, "scoreA"),
        scoreB: optInt(entry, "scoreB")))

proc parseTeam(body: JsonNode): TeamTournament =
  if body.kind != JObject:
    raise newException(ValueError, "tournament body must be an object")
  result.name = text(body, "name")
  result.date = text(body, "date")
  if result.date.len > 0 and not validDate(result.date):
    raise newException(ValueError, "date must be a valid YYYY-MM-DD value")
  result.version = optInt(body, "version")
  if body.hasKey("teams") and body["teams"].kind notin {JArray, JNull}:
    raise newException(ValueError, "teams must be a list")
  if body.hasKey("teams") and body["teams"].kind == JArray:
    for raw in body["teams"]:
      let entry = objectEntry(raw)
      var team = TeamInfo(id: text(entry, "id"), name: text(entry, "name"))
      if entry.hasKey("players") and entry["players"].kind == JArray:
        for rawPlayer in entry["players"]:
          let player = objectEntry(rawPlayer)
          team.players.add(TeamPlayer(name: text(player, "name"),
            cls: parseEnum[TeamClass](text(player, "cls"))))
      result.teams.add(team)
  if body.hasKey("matches") and body["matches"].kind notin {JArray, JNull}:
    raise newException(ValueError, "matches must be a list")
  if body.hasKey("matches") and body["matches"].kind == JArray:
    for raw in body["matches"]:
      let entry = objectEntry(raw)
      var match = TeamMatch(id: text(entry, "id"),
        phase: parseEnum[TeamPhase](text(entry, "phase")),
        teamA: text(entry, "teamA"), teamB: text(entry, "teamB"),
        courts: [defaultCourts[0], defaultCourts[1], defaultCourts[2]])
      if entry.hasKey("courts") and entry["courts"].kind == JArray:
        for index in 0 ..< min(3, entry["courts"].len):
          if entry["courts"][index].kind != JString:
            raise newException(ValueError, "court names must be strings")
          match.courts[index] = entry["courts"][index].getStr()
      if entry.hasKey("partai") and entry["partai"].kind == JArray:
        for rawPartai in entry["partai"]:
          let partai = objectEntry(rawPartai)
          let scoreA = optInt(partai, "scoreA")
          let scoreB = optInt(partai, "scoreB")
          # A partai with one side only would reach `scoreB.get` below and
          # raise a defect, which the route reports as a 500.
          if scoreA.isNone != scoreB.isNone:
            raise newException(ValueError,
              "partai scoreA and scoreB must be sent together")
          if scoreA.isSome and (scoreA.get < 0 or scoreA.get > 99 or
              scoreB.get < 0 or scoreB.get > 99):
            raise newException(ValueError,
              "partai scores must be between 0 and 99")
          match.partai.add(TeamPartai(scoreA: scoreA, scoreB: scoreB))
      result.matches.add(match)

# ── reads ──────────────────────────────────────────────────────────────────

proc loadClassic(db: Db, communityId, id: string, header: Row): JsonNode =
  let tournament = @[textParam(communityId), textParam(id)]
  var pairs = newJArray()
  for row in db.query(
      """select id::text as id, display_name from tournament.pairs
         where community_id = $1::uuid and tournament_id = $2::uuid
         order by display_name, id""", tournament):
    pairs.add(%*{"id": row.get("id"), "name": row.get("display_name")})
  var groups = %*{"A": [], "B": [], "C": [], "D": []}
  for row in db.query(
      """select group_id, pair_id::text as pair_id from tournament.groups
         where community_id = $1::uuid and tournament_id = $2::uuid
         order by group_id, position""", tournament):
    groups[row.get("group_id")].add(%row.get("pair_id"))
  var matches = newJArray()
  for row in db.query(
      """select coalesce(match_key, id::text) as id, phase, group_id,
                pair_a_id::text as pair_a_id, pair_b_id::text as pair_b_id,
                score_a, score_b
         from tournament.matches
         where community_id = $1::uuid and tournament_id = $2::uuid
         order by match_order""", tournament):
    matches.add(%*{
      "id": row.get("id"),
      "phase": row.get("phase"),
      "groupId": if row["group_id"].isNone: newJNull() else: %row.get("group_id"),
      "pairAId": if row["pair_a_id"].isNone: newJNull() else: %row.get("pair_a_id"),
      "pairBId": if row["pair_b_id"].isNone: newJNull() else: %row.get("pair_b_id"),
      "scoreA": if row["score_a"].isNone: newJNull() else: %parseInt(row.get("score_a")),
      "scoreB": if row["score_b"].isNone: newJNull() else: %parseInt(row.get("score_b")),
    })
  %*{"version": parseInt(header.get("version")), "format": "classic",
     "name": header.get("name"), "date": header.get("date"),
     "pairs": pairs, "groups": groups, "matches": matches}

proc loadTeam(db: Db, communityId, id: string, header: Row): JsonNode =
  let tournament = @[textParam(communityId), textParam(id)]
  var teams = newJArray()
  for row in db.query(
      """select id::text as id, team_name from tournament.teams
         where community_id = $1::uuid and tournament_id = $2::uuid
         order by seed""", tournament):
    var players = newJArray()
    for member in db.query(
        """select player_name, cls from tournament.team_players
           where community_id = $1::uuid and team_id = $2::uuid
           order by case cls when 'A+' then 0 when 'A' then 1 when 'B+' then 2
                             when 'B' then 3 when 'C+' then 4 else 5 end""",
        @[textParam(communityId), textParam(row.get("id"))]):
      players.add(%*{"name": member.get("player_name"), "cls": member.get("cls")})
    teams.add(%*{"id": row.get("id"), "name": row.get("team_name"),
      "players": players})
  var matches = newJArray()
  for row in db.query(
      """select id::text as row_id, coalesce(match_key, id::text) as id, phase,
                team_a_id::text as team_a_id, team_b_id::text as team_b_id,
                to_json(courts)::text as courts
         from tournament.team_matches
         where community_id = $1::uuid and tournament_id = $2::uuid
         order by match_order""", tournament):
    var partai = newJArray()
    for index in 0 ..< 3:
      partai.add(%*{"scoreA": newJNull(), "scoreB": newJNull()})
    for game in db.query(
        """select partai_index, score_a, score_b from tournament.team_partai
           where community_id = $1::uuid and team_match_id = $2::uuid
           order by partai_index""",
        @[textParam(communityId), textParam(row.get("row_id"))]):
      let index = parseInt(game.get("partai_index"))
      if index in 0 .. 2:
        partai.elems[index] = %*{
          "scoreA": if game["score_a"].isNone: newJNull() else: %parseInt(game.get("score_a")),
          "scoreB": if game["score_b"].isNone: newJNull() else: %parseInt(game.get("score_b"))}
    matches.add(%*{
      "id": row.get("id"), "phase": row.get("phase"),
      "teamA": if row["team_a_id"].isNone: "" else: row.get("team_a_id"),
      "teamB": if row["team_b_id"].isNone: "" else: row.get("team_b_id"),
      "partai": partai, "courts": parseJson(row.get("courts"))})
  %*{"version": parseInt(header.get("version")), "format": "team",
     "name": header.get("name"), "date": header.get("date"),
     "teams": teams, "matches": matches}

proc load*(db: Db, communityId, id: string): Option[JsonNode] =
  let header = db.queryOne(
    """select format, name, event_date::text as date, version
       from tournament.tournaments
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(id)])
  if header.isNone:
    return none(JsonNode)
  case header.get.get("format")
  of "classic": some(loadClassic(db, communityId, id, header.get))
  of "team": some(loadTeam(db, communityId, id, header.get))
  else: none(JsonNode)

proc list*(db: Db, communityId, format: string, limit, offset: int): seq[JsonNode] =
  var params = @[textParam(communityId)]
  var sql = """select id, name, event_date::text as date, format, status, version
               from tournament.tournaments where community_id = $1::uuid"""
  if format in ["classic", "team"]:
    sql.add(" and format = $2")
    params.add(textParam(format))
  sql.add(" order by event_date desc, created_at desc limit $" & $(params.len + 1) &
    " offset $" & $(params.len + 2))
  params.add(intParam(max(1, min(limit, 100)).int64))
  params.add(intParam(max(0, offset).int64))
  for row in db.query(sql, params):
    result.add(%*{"id": row.get("id"), "name": row.get("name"),
      "date": row.get("date"), "format": row.get("format"),
      "status": row.get("status"), "version": parseInt(row.get("version"))})

# ── child writes ───────────────────────────────────────────────────────────

proc splitNames(display: string): (string, string) =
  ## Pair display names are "A & B" (also "vs", "," or "/"). v1 registered the
  ## players it could split; the schema needs two, so a lone name is paired with
  ## a deterministic second label instead of leaving a NOT NULL hole.
  var cleaned = display
  for separator in [" & ", " vs ", " VS ", ",", "/"]:
    cleaned = cleaned.replace(separator, "|")
  var names: seq[string] = @[]
  for part in cleaned.split('|'):
    if part.strip().len > 0:
      names.add(part.strip())
  if names.len == 0:
    return ("TBD A", "TBD B")
  if names.len == 1:
    return (names[0], names[0] & " #2")
  if playerDomain.normalizeName(names[0]).toLowerAscii() ==
     playerDomain.normalizeName(names[1]).toLowerAscii():
    return (names[0], names[1] & " #2")
  (names[0], names[1])

proc playerId(conn: DbConn, communityId, name: string): string =
  let lookup = """select id from player.players
                  where community_id = $1::uuid
                    and canonical_key = btrim(regexp_replace(lower($2), '\s+', ' ', 'g'))"""
  let params = @[textParam(communityId), textParam(name)]
  let found = conn.queryOne(lookup, params)
  if found.isSome:
    return found.get.get("id")
  let inserted = conn.queryOne(
    """insert into player.players (community_id, canonical_name)
       values ($1::uuid, $2) on conflict (community_id, canonical_key) do nothing
       returning id""", params)
  if inserted.isSome:
    return inserted.get.get("id")
  conn.queryOne(lookup, params).get.get("id")

proc pickId(candidate: string, owned: Table[string, bool]): string =
  if candidate.len > 0 and owned.hasKey(candidate): candidate else: uuidv7()

proc roundOf(phase: ClassicPhase): int =
  case phase
  of cpGroup: 0
  of cpQf: 1
  of cpSf: 2
  of cpThird: 3
  of cpFinal: 4

proc writeClassic(conn: DbConn, communityId, tournamentId: string,
                  data: ClassicTournament, owned: Owned) =
  var pairMap = initTable[string, string]()
  for pair in data.pairs:
    let names = splitNames(pair.name)
    let pairRow = pickId(pair.id, owned.pairs)
    pairMap[pair.id] = pairRow
    discard conn.execUpdate(
      """insert into tournament.pairs
           (id, community_id, tournament_id, display_name, player_a_id, player_b_id)
         values ($1::uuid, $2::uuid, $3::uuid, $4, $5::uuid, $6::uuid)""",
      @[textParam(pairRow), textParam(communityId), textParam(tournamentId),
        textParam(pair.name),
        textParam(playerId(conn, communityId, names[0])),
        textParam(playerId(conn, communityId, names[1]))])
  for groupId in GroupIds:
    for position, pairRef in data.groups[ord(groupId)]:
      let pairRow = pairMap.getOrDefault(pairRef)
      if pairRow.len == 0:
        continue
      discard conn.execUpdate(
        """insert into tournament.groups
             (community_id, tournament_id, group_id, pair_id, position)
           values ($1::uuid, $2::uuid, $3, $4::uuid, $5)""",
        @[textParam(communityId), textParam(tournamentId), textParam($groupId),
          textParam(pairRow), intParam(position.int64)])
  for order, match in data.matches:
    let pairA = if match.pairAId.isSome:
      pairMap.getOrDefault(match.pairAId.get) else: ""
    let pairB = if match.pairBId.isSome:
      pairMap.getOrDefault(match.pairBId.get) else: ""
    discard conn.execUpdate(
      """insert into tournament.matches
           (id, community_id, tournament_id, round_no, pair_a_id, pair_b_id,
            score_a, score_b, status, phase, group_id, match_key, match_order)
         values ($1::uuid, $2::uuid, $3::uuid, $4, $5::uuid, $6::uuid, $7, $8,
                 $9, $10, $11, $12, $13)""",
      @[textParam(uuidv7()), textParam(communityId),
        textParam(tournamentId), intParam(roundOf(match.phase).int64),
        (if pairA.len > 0: textParam(pairA) else: nullParam()),
        (if pairB.len > 0: textParam(pairB) else: nullParam()),
        (if match.scoreA.isSome: intParam(match.scoreA.get.int64) else: nullParam()),
        (if match.scoreB.isSome: intParam(match.scoreB.get.int64) else: nullParam()),
        textParam(if match.scoreA.isSome: "played" else: "scheduled"),
        textParam($match.phase),
        (if match.groupId.isSome: textParam($match.groupId.get) else: nullParam()),
        textParam(if match.id.len > 0: match.id else: "m-" & $order),
        intParam(order.int64)])

proc writeTeam(conn: DbConn, communityId, tournamentId: string,
               data: TeamTournament, owned: Owned) =
  var teamMap = initTable[string, string]()
  for index, team in data.teams:
    let teamRow = pickId(team.id, owned.teams)
    teamMap[team.id] = teamRow
    discard conn.execUpdate(
      """insert into tournament.teams
           (id, community_id, tournament_id, seed, team_name)
         values ($1::uuid, $2::uuid, $3::uuid, $4, $5)""",
      @[textParam(teamRow), textParam(communityId), textParam(tournamentId),
        intParam((index + 1).int64), textParam(team.name)])
    for player in team.players:
      # A roster is names plus classes; resolving the name to a registered
      # player is what lets the team format earn rating deltas later.
      discard conn.execUpdate(
        """insert into tournament.team_players
             (community_id, team_id, player_name, player_id, cls)
           values ($1::uuid, $2::uuid, $3, $4::uuid, $5)""",
        @[textParam(communityId), textParam(teamRow), textParam(player.name),
          textParam(playerId(conn, communityId, player.name)),
          textParam($player.cls)])
  for order, match in data.matches:
    let teamA = teamMap.getOrDefault(match.teamA)
    let teamB = teamMap.getOrDefault(match.teamB)
    let matchRow = uuidv7()
    discard conn.execUpdate(
      """insert into tournament.team_matches
           (id, community_id, tournament_id, phase, match_order, match_key,
            team_a_id, team_b_id, courts)
         values ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6, $7::uuid, $8::uuid,
                 array(select jsonb_array_elements_text($9::jsonb))::text[])""",
      @[textParam(matchRow), textParam(communityId), textParam(tournamentId),
        textParam($match.phase), intParam(order.int64),
        textParam(if match.id.len > 0: match.id else: "tm-" & $order),
        (if teamA.len > 0: textParam(teamA) else: nullParam()),
        (if teamB.len > 0: textParam(teamB) else: nullParam()),
        textParam($(%*[match.courts[0], match.courts[1], match.courts[2]]))])
    for index, partai in match.partai:
      discard conn.execUpdate(
        """insert into tournament.team_partai
             (community_id, team_match_id, partai_index, score_a, score_b)
           values ($1::uuid, $2::uuid, $3, $4, $5)""",
        @[textParam(communityId), textParam(matchRow), intParam(index.int64),
          (if partai.scoreA.isSome: intParam(partai.scoreA.get.int64) else: nullParam()),
          (if partai.scoreB.isSome: intParam(partai.scoreB.get.int64) else: nullParam())])

proc ownedIds(conn: DbConn, table, communityId, tournamentId: string): Table[string, bool] =
  for row in conn.query(
      "select id::text as id from " & table &
      " where community_id = $1::uuid and tournament_id = $2::uuid",
      @[textParam(communityId), textParam(tournamentId)]):
    result[row.get("id")] = true

proc ownedFor(conn: DbConn, communityId, tournamentId: string): Owned =
  Owned(pairs: ownedIds(conn, "tournament.pairs", communityId, tournamentId),
    teams: ownedIds(conn, "tournament.teams", communityId, tournamentId))

proc clearChildren(conn: DbConn, communityId, tournamentId: string) =
  ## Children first: matches/groups and team rows restrict the parent deletes.
  let params = @[textParam(communityId), textParam(tournamentId)]
  for statement in [
      """delete from tournament.team_partai
         where community_id = $1::uuid and team_match_id in
           (select id from tournament.team_matches
            where community_id = $1::uuid and tournament_id = $2::uuid)""",
      """delete from tournament.team_matches
         where community_id = $1::uuid and tournament_id = $2::uuid""",
      """delete from tournament.team_players
         where community_id = $1::uuid and team_id in
           (select id from tournament.teams
            where community_id = $1::uuid and tournament_id = $2::uuid)""",
      """delete from tournament.teams
         where community_id = $1::uuid and tournament_id = $2::uuid""",
      """delete from tournament.groups
         where community_id = $1::uuid and tournament_id = $2::uuid""",
      """delete from tournament.matches
         where community_id = $1::uuid and tournament_id = $2::uuid""",
      """delete from tournament.pairs
         where community_id = $1::uuid and tournament_id = $2::uuid"""]:
    discard conn.execUpdate(statement, params)

# ── writes ─────────────────────────────────────────────────────────────────

proc insertHeader(conn: DbConn, communityId, name, date, format: string): string =
  result = uuidv7()
  discard conn.execUpdate(
    """insert into tournament.tournaments
         (id, community_id, name, event_date, format, version, status)
       values ($1::uuid, $2::uuid, $3, $4::date, $5, 1, 'draft')""",
    @[textParam(result), textParam(communityId), textParam(name),
      textParam(date), textParam(format)])

proc create*(db: Db, communityId, actorId: string,
             body: JsonNode): (SaveStatus, JsonNode) =
  discard actorId
  let format = probeFormat(body)
  if format == "team":
    var data: TeamTournament
    try: data = parseTeam(body)
    except ValueError as error: return (svInvalid, failure("invalid_body", error.msg))
    let issues = validate(data)
    if issues.len > 0:
      return (svInvalid, invalid(issuesJson(issues)))
    let id = db.tx(proc(conn: DbConn): string =
      result = insertHeader(conn, communityId, data.name, data.date, "team")
      writeTeam(conn, communityId, result, data, Owned()))
    return (svOk, withId(load(db, communityId, id).get, id))
  var data: ClassicTournament
  try: data = parseClassic(body)
  except ValueError as error: return (svInvalid, failure("invalid_body", error.msg))
  let issues = validate(data)
  if issues.len > 0:
    return (svInvalid, invalid(issuesJson(issues)))
  let id = db.tx(proc(conn: DbConn): string =
    result = insertHeader(conn, communityId, data.name, data.date, "classic")
    writeClassic(conn, communityId, result, data, Owned()))
  (svOk, withId(load(db, communityId, id).get, id))

proc lockHeader(conn: DbConn, communityId, id, name, date: string,
                expectedVersion: int): SaveStatus =
  ## Row lock, optimistic check and header update. Children are cleared by the
  ## caller after it has captured their ids for reuse. A finalized source is
  ## signed off for the ledger, so editing it would leave the board rating a
  ## bracket nobody can see any more.
  let header = conn.queryOne(
    """select t.version, coalesce(s.finalized, false) as finalized
       from tournament.tournaments t
       left join rating.sources s
         on s.community_id = t.community_id and s.source_id = t.id
       where t.community_id = $1::uuid and t.id = $2::uuid for update of t""",
    @[textParam(communityId), textParam(id)])
  if header.isNone:
    return svNotFound
  if header.get.get("finalized") == "t":
    return svLocked
  if parseInt(header.get.get("version")) != expectedVersion:
    return svStale
  discard conn.execUpdate(
    """update tournament.tournaments
       set name = $3, event_date = $4::date, version = version + 1,
           updated_at = now()
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(id), textParam(name), textParam(date)])
  svOk

proc replaceClassic(conn: DbConn, communityId, id: string,
                    data: ClassicTournament, expectedVersion: int): SaveStatus =
  result = lockHeader(conn, communityId, id, data.name, data.date, expectedVersion)
  if result != svOk:
    return
  let owned = ownedFor(conn, communityId, id)
  clearChildren(conn, communityId, id)
  writeClassic(conn, communityId, id, data, owned)

proc replaceTeam(conn: DbConn, communityId, id: string,
                 data: TeamTournament, expectedVersion: int): SaveStatus =
  result = lockHeader(conn, communityId, id, data.name, data.date, expectedVersion)
  if result != svOk:
    return
  let owned = ownedFor(conn, communityId, id)
  clearChildren(conn, communityId, id)
  writeTeam(conn, communityId, id, data, owned)

proc replace*(db: Db, communityId, id, actorId: string, body: JsonNode,
              expectedVersion: int): (SaveStatus, JsonNode) =
  discard actorId
  let stored = db.queryOne(
    """select format from tournament.tournaments
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(id)])
  if stored.isNone:
    return (svNotFound, newJObject())
  let format = stored.get.get("format")
  if probeFormat(body) != format:
    return (svInvalid, failure("format_mismatch",
      "tournament is " & format & ", body is " & probeFormat(body)))
  var status = svOk
  if format == "team":
    var data: TeamTournament
    try: data = parseTeam(body)
    except ValueError as error: return (svInvalid, failure("invalid_body", error.msg))
    let issues = validate(data)
    if issues.len > 0:
      return (svInvalid, invalid(issuesJson(issues)))
    discard db.tx(proc(conn: DbConn): int =
      status = replaceTeam(conn, communityId, id, data, expectedVersion)
      0)
  else:
    var data: ClassicTournament
    try: data = parseClassic(body)
    except ValueError as error: return (svInvalid, failure("invalid_body", error.msg))
    let issues = validate(data)
    if issues.len > 0:
      return (svInvalid, invalid(issuesJson(issues)))
    discard db.tx(proc(conn: DbConn): int =
      status = replaceClassic(conn, communityId, id, data, expectedVersion)
      0)
  if status != svOk:
    return (status, newJObject())
  (svOk, withId(load(db, communityId, id).get, id))


proc remove*(db: Db, communityId, id: string): bool =
  db.tx(proc(conn: DbConn): int =
    clearChildren(conn, communityId, id)
    result = conn.execUpdate(
      """delete from tournament.tournaments
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(id)])) > 0

# ── match patch ────────────────────────────────────────────────────────────

proc parseScores(body: JsonNode): (Option[int], Option[int]) =
  if body.kind != JObject or not body.hasKey("scoreA") or
     not body.hasKey("scoreB"):
    raise newException(ValueError, "scoreA and scoreB are required")
  let scoreA = optInt(body, "scoreA")
  let scoreB = optInt(body, "scoreB")
  if scoreA.isNone != scoreB.isNone:
    raise newException(ValueError, "scoreA and scoreB must be sent together")
  if scoreA.isSome:
    if scoreA.get < 0 or scoreA.get > 99 or scoreB.get < 0 or scoreB.get > 99:
      raise newException(ValueError, "scores must be between 0 and 99")
    if scoreA.get == scoreB.get:
      raise newException(ValueError, "a played match cannot be tied")
  (scoreA, scoreB)

proc patchClassic(conn: DbConn, communityId, tournamentId, matchId: string,
                  body: JsonNode): bool =
  let scores = parseScores(body)
  conn.execUpdate(
    """update tournament.matches
       set score_a = $4::int, score_b = $5::int,
           status = case when $4::int is null then 'scheduled' else 'played' end,
           updated_at = now()
       where community_id = $1::uuid and tournament_id = $2::uuid
         and coalesce(match_key, id::text) = $3""",
    @[textParam(communityId), textParam(tournamentId), textParam(matchId),
      (if scores[0].isSome: intParam(scores[0].get.int64) else: nullParam()),
      (if scores[1].isSome: intParam(scores[1].get.int64) else: nullParam())]) > 0

proc patchTeam(conn: DbConn, communityId, tournamentId, matchId: string,
               body: JsonNode): bool =
  if body.kind != JObject:
    raise newException(ValueError, "patch body must be an object")
  let exists = conn.queryOne(
    """select id::text as id from tournament.team_matches
       where community_id = $1::uuid and tournament_id = $2::uuid
         and coalesce(match_key, id::text) = $3""",
    @[textParam(communityId), textParam(tournamentId), textParam(matchId)])
  if exists.isNone:
    return false
  let matchRow = exists.get.get("id")
  # Parse and validate everything first. Writing partai one by one meant a bad
  # third entry left the first two committed and the ETag untouched, so another
  # writer could not even see the change.
  var courtNames: seq[string] = @[]
  if body.hasKey("courts"):
    let courts = body["courts"]
    if courts.kind != JArray or courts.len != 3:
      raise newException(ValueError, "courts must contain three names")
    for court in courts:
      if court.kind != JString:
        raise newException(ValueError, "court names must be strings")
      courtNames.add(court.getStr())
  var partaiScores: seq[(Option[int], Option[int])] = @[]
  if body.hasKey("partai"):
    let partai = body["partai"]
    if partai.kind != JArray or partai.len != 3:
      raise newException(ValueError, "partai must contain three entries")
    for rawEntry in partai:
      partaiScores.add(parseScores(objectEntry(rawEntry)))
  if courtNames.len == 0 and partaiScores.len == 0:
    raise newException(ValueError, "courts or partai is required")
  if courtNames.len > 0:
    discard conn.execUpdate(
      """update tournament.team_matches
         set courts = array(select jsonb_array_elements_text($4::jsonb))::text[]
         where community_id = $1::uuid and tournament_id = $2::uuid
           and coalesce(match_key, id::text) = $3""",
      @[textParam(communityId), textParam(tournamentId), textParam(matchId),
        textParam($(%*[courtNames[0], courtNames[1], courtNames[2]]))])
  for index, scores in partaiScores:
    discard conn.execUpdate(
      """insert into tournament.team_partai
           (community_id, team_match_id, partai_index, score_a, score_b)
         values ($1::uuid, $2::uuid, $3, $4, $5)
         on conflict (team_match_id, partai_index) do update
           set score_a = excluded.score_a, score_b = excluded.score_b""",
      @[textParam(communityId), textParam(matchRow), intParam(index.int64),
        (if scores[0].isSome: intParam(scores[0].get.int64) else: nullParam()),
        (if scores[1].isSome: intParam(scores[1].get.int64) else: nullParam())])
  true

proc patchMatch*(db: Db, communityId, id, matchId: string, body: JsonNode,
                 expectedVersion: int): (PatchStatus, JsonNode) =
  var status = ptOk
  var detail = newJObject()
  discard db.tx(proc(conn: DbConn): int =
    let header = conn.queryOne(
      """select t.format, t.version, coalesce(s.finalized, false) as finalized
         from tournament.tournaments t
         left join rating.sources s
           on s.community_id = t.community_id and s.source_id = t.id
         where t.community_id = $1::uuid and t.id = $2::uuid for update of t""",
      @[textParam(communityId), textParam(id)])
    if header.isNone:
      status = ptNotFound
      return 0
    if header.get.get("finalized") == "t":
      status = ptLocked
      return 0
    if parseInt(header.get.get("version")) != expectedVersion:
      status = ptStale
      return 0
    var applied = false
    try:
      if header.get.get("format") == "team":
        applied = patchTeam(conn, communityId, id, matchId, body)
      else:
        applied = patchClassic(conn, communityId, id, matchId, body)
    except ValueError as error:
      status = ptInvalid
      detail = failure("invalid_body", error.msg)
      return 0
    if not applied:
      status = ptNotFound
      return 0
    discard conn.execUpdate(
      """update tournament.tournaments
         set version = version + 1, updated_at = now()
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(id)])
    0)
  if status != ptOk:
    return (status, detail)
  (ptOk, withId(load(db, communityId, id).get, id))
