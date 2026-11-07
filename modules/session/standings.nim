## Session standings: the tally the v1 client computed, now served once.
##
## A played game counts only when both sides still have a real participant:
## absent players are excluded from the tally, and a side made only of absent
## players drops the whole game. The order is the v1 one — wins, then point
## difference, then points for, then the player name so ties are stable.

import std/[algorithm, json, options, tables]
import db/db

type
  Tally = object
    playerId: string
    name: string
    wins: int
    losses: int
    pointsFor: int
    pointsAgainst: int

proc sidePlayers(row: Row, side: string): seq[string] =
  for slot in ["1", "2"]:
    let key = side & slot
    let value = row.getOpt(key)
    if value.isSome and value.get.len > 0:
      result.add(value.get)

proc without(players, skipped: seq[string]): seq[string] =
  for player in players:
    if player notin skipped:
      result.add(player)

proc hasReal(players: seq[string], rows: Table[string, Tally]): bool =
  for player in players:
    if rows.hasKey(player):
      return true

proc compute*(db: Db, communityId, sessionId: string): Option[JsonNode] =
  ## The board for one session, or none when the session is not in this
  ## community. Games the server never saw as played are ignored.
  let session = db.queryOne(
    """select id, title, session_date::text as session_date
       from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)])
  if session.isNone:
    return none(JsonNode)

  var rows = initTable[string, Tally]()
  var order: seq[string] = @[]
  for row in db.query(
    """select p.player_id, pl.canonical_name as name, p.is_absent
       from session.participants p
       join player.players pl on pl.id = p.player_id
       where p.community_id = $1::uuid and p.session_id = $2::uuid
       order by pl.canonical_name""",
    @[textParam(communityId), textParam(sessionId)]):
    if row.getBool("is_absent"):
      continue
    let playerId = row.getUuid("player_id")
    rows[playerId] = Tally(playerId: playerId, name: row.get("name"))
    order.add(playerId)

  var skips = initTable[string, seq[string]]()
  for row in db.query(
    """select round_no, court_no, player_id::text as player_id
       from session.game_skips
       where community_id = $1::uuid and session_id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)]):
    let key = row.get("round_no") & "-" & row.get("court_no")
    skips.mgetOrPut(key, @[]).add(row.getUuid("player_id"))

  for game in db.query(
    """select round_no, court_no, winner, points_a, points_b,
              coalesce(side_a1::text, '') as side_a1,
              coalesce(side_a2::text, '') as side_a2,
              coalesce(side_b1::text, '') as side_b1,
              coalesce(side_b2::text, '') as side_b2
       from session.game_results
       where community_id = $1::uuid and session_id = $2::uuid
         and status = 'played' and winner <> ''
       order by round_no, court_no""",
    @[textParam(communityId), textParam(sessionId)]):
    let key = game.get("round_no") & "-" & game.get("court_no")
    let skipped = skips.getOrDefault(key)
    let sideA = sidePlayers(game, "side_a")
    let sideB = sidePlayers(game, "side_b")
    # Absence removes the game: a side with no present participant has no one
    # to tally. A per-game skip only removes those players from the tally, so
    # the opposing side still gets the result unless both sides end up empty.
    if not sideA.hasReal(rows) or not sideB.hasReal(rows):
      continue
    let activeA = without(sideA, skipped)
    let activeB = without(sideB, skipped)
    if activeA.len == 0 and activeB.len == 0:
      continue
    let aWon = game.get("winner") == "a"
    let pointsA = game.getInt("points_a")
    let pointsB = game.getInt("points_b")
    for playerId in activeA:
      if not rows.hasKey(playerId):
        continue
      var tally = rows[playerId]
      if aWon: tally.wins.inc else: tally.losses.inc
      tally.pointsFor += pointsA
      tally.pointsAgainst += pointsB
      rows[playerId] = tally
    for playerId in activeB:
      if not rows.hasKey(playerId):
        continue
      var tally = rows[playerId]
      if aWon: tally.losses.inc else: tally.wins.inc
      tally.pointsFor += pointsB
      tally.pointsAgainst += pointsA
      rows[playerId] = tally

  var board: seq[Tally] = @[]
  for playerId in order:
    board.add(rows[playerId])
  board.sort(proc(a, b: Tally): int =
    result = cmp(b.wins, a.wins)
    if result != 0:
      return
    result = cmp(b.pointsFor - b.pointsAgainst, a.pointsFor - a.pointsAgainst)
    if result != 0:
      return
    result = cmp(b.pointsFor, a.pointsFor)
    if result != 0:
      return
    result = cmp(a.name, b.name))

  var items = newJArray()
  for tally in board:
    items.add(%*{
      "playerId": tally.playerId,
      "name": tally.name,
      "wins": tally.wins,
      "losses": tally.losses,
      "pointsFor": tally.pointsFor,
      "pointsAgainst": tally.pointsAgainst,
      "diff": tally.pointsFor - tally.pointsAgainst,
    })
  some(%*{
    "sessionId": session.get.get("id"),
    "title": session.get.get("title"),
    "date": session.get.get("session_date"),
    "items": items,
  })
