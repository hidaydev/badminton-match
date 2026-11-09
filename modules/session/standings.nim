## Session standings: the tally the v1 client computed, now served once.
##
## A played game counts only when both sides still have a real participant:
## absent players are excluded from the tally, and a side made only of absent
## players drops the whole game. The order is the v1 one — wins, then point
## difference, then points for, then the player name so ties are stable.

import std/[algorithm, json, options, sets, tables]
import db/db
import ./sides

type
  Tally = object
    playerId: string
    name: string
    wins: int
    losses: int
    pointsFor: int
    pointsAgainst: int

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

  var absent = initHashSet[string]()
  var rows = initTable[string, Tally]()
  var order: seq[string] = @[]
  for row in db.query(
    """select p.player_id, pl.canonical_name as name, p.is_absent
       from session.participants p
       join player.players pl on pl.id = p.player_id
       where p.community_id = $1::uuid and p.session_id = $2::uuid
       order by pl.canonical_name""",
    @[textParam(communityId), textParam(sessionId)]):
    let playerId = row.getUuid("player_id")
    if row.getBool("is_absent"):
      absent.incl(playerId)
      continue
    rows[playerId] = Tally(playerId: playerId, name: row.get("name"))
    order.add(playerId)

  var skips = initTable[string, HashSet[string]]()
  for row in db.query(
    """select round_no, court_no, player_id::text as player_id
       from session.game_skips
       where community_id = $1::uuid and session_id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)]):
    let key = row.get("round_no") & "-" & row.get("court_no")
    skips.mgetOrPut(key, initHashSet[string]()).incl(row.getUuid("player_id"))

  for game in db.query(
    """select round_no, court_no, winner, points_a, points_b,
              """ & gameSideColumns & """
       from session.game_results
       where community_id = $1::uuid and session_id = $2::uuid
         and status = 'played' and winner <> ''
       order by round_no, court_no""",
    @[textParam(communityId), textParam(sessionId)]):
    let key = game.get("round_no") & "-" & game.get("court_no")
    let split = sides(game.get("side_a1"), game.get("side_a2"),
      game.get("side_b1"), game.get("side_b2"), absent,
      skips.getOrDefault(key))
    if not split.counts:
      continue
    let aWon = game.get("winner") == "a"
    let pointsA = game.getInt("points_a")
    let pointsB = game.getInt("points_b")
    for playerId in split.eligibleA:
      if not rows.hasKey(playerId):
        continue
      var tally = rows[playerId]
      if aWon: tally.wins.inc else: tally.losses.inc
      tally.pointsFor += pointsA
      tally.pointsAgainst += pointsB
      rows[playerId] = tally
    for playerId in split.eligibleB:
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
