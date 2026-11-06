import std/[json, options, strutils]
import db/db
import ./scoring
import skips

type
  Slots = object
    ## The four side columns of one game; "" is an empty position.
    a1: string
    a2: string
    b1: string
    b2: string

  SwapKind* = enum
    skPlayer = "player"
    skTeam = "team"
    skSlot = "slot"

  SwapTarget* = object
    ## `slot` is `round_no` and `court` is `court_no`. A slot swap ignores
    ## `team` and `position`; the other kinds ignore neither.
    slot*: int
    court*: int
    team*: string
    position*: int

  SwapPatch* = object
    ## `kind` is none when the body is invalid; `error` then says why.
    kind*: Option[SwapKind]
    a*: SwapTarget
    b*: SwapTarget
    error*: string

  SwapStatus* = enum
    swOk = "ok"
    swNotFound = "not_found"
    swStale = "stale"
    swInvalid = "invalid"
    swLocked = "locked"

  SwapOutcome* = object
    status*: SwapStatus
    version*: int
    sessionStatus*: string
    detail*: string

  GameContent = object
    slots: Slots
    ## The result travels with the slot: a swapped game keeps the sets that were
    ## recorded for it, not the ones recorded for the position it lands in.
    sets: seq[SetScore]
    status: string

proc swapError(kind: SwapKind, a, b: SwapTarget): string =
  ## The v1 validation, in the same order (store/swap.go:36-70): magnitude and
  ## same-game rules first, then the team/position shape.
  if a.slot < 0 or a.court < 0 or b.slot < 0 or b.court < 0:
    return "swap targets must be non-negative"
  let sameGame = a.slot == b.slot and a.court == b.court
  if sameGame:
    if kind == skSlot:
      return "swap targets must be different games"
    if a.team == b.team and a.position == b.position:
      return "swap targets must be different positions"
  if kind == skSlot:
    return ""
  for target in [a, b]:
    if target.team != "A" and target.team != "B":
      return "swap target team must be A or B"
    if target.position != 0 and target.position != 1:
      return "swap target position must be 0 or 1"
  if kind == skTeam:
    # store/swap.go:287-289 wants the same side letter across games, while
    # swapTeamSameGame (:393-395) wants two different sides in one game.
    if sameGame and a.team == b.team:
      return "team swap within one game needs two different teams"
    if not sameGame and a.team != b.team:
      return "swap across games needs the same team letter"
  ""

proc parseTarget(node: JsonNode): Option[SwapTarget] =
  ## Go's decoder zero-fills omitted fields, so a missing key is 0 or ""; only a
  ## wrong JSON type makes the body malformed.
  if node.kind != JObject:
    return none(SwapTarget)
  var target = SwapTarget()
  if node.hasKey("slot") and node["slot"].kind != JNull:
    if node["slot"].kind != JInt:
      return none(SwapTarget)
    target.slot = node["slot"].getInt()
  if node.hasKey("court") and node["court"].kind != JNull:
    if node["court"].kind != JInt:
      return none(SwapTarget)
    target.court = node["court"].getInt()
  if node.hasKey("position") and node["position"].kind != JNull:
    if node["position"].kind != JInt:
      return none(SwapTarget)
    target.position = node["position"].getInt()
  if node.hasKey("team") and node["team"].kind != JNull:
    if node["team"].kind != JString:
      return none(SwapTarget)
    target.team = node["team"].getStr()
  some(target)

proc parseKind(node: JsonNode): Option[SwapKind] =
  if node.kind != JString:
    return none(SwapKind)
  case node.getStr().toLowerAscii().strip()
  of "player": some(skPlayer)
  of "team": some(skTeam)
  of "slot": some(skSlot)
  else: none(SwapKind)

proc parseSwap*(body: JsonNode): SwapPatch =
  ## The v1 handler decoded the body into a struct, so every failure here was a
  ## 400 validation error; this returns it as an outcome instead of raising.
  if body.kind != JObject:
    result.error = "swap body must be an object"
    return
  if not body.hasKey("type"):
    result.error = "swap type must be player|team|slot"
    return
  let kind = parseKind(body["type"])
  if kind.isNone:
    result.error = "swap type must be player|team|slot"
    return
  let a = if body.hasKey("a"): parseTarget(body["a"]) else: some(SwapTarget())
  let b = if body.hasKey("b"): parseTarget(body["b"]) else: some(SwapTarget())
  if a.isNone or b.isNone:
    result.error = "swap targets must be objects"
    return
  result.a = a.get
  result.b = b.get
  result.error = swapError(kind.get, result.a, result.b)
  if result.error.len > 0:
    return
  result.kind = kind

proc at(slots: Slots, target: SwapTarget): string =
  ## A NULL slot reads as "" and an unknown team never matches a column.
  let first = target.position == 0
  case target.team
  of "A": result = if first: slots.a1 else: slots.a2
  of "B": result = if first: slots.b1 else: slots.b2
  else: result = ""

proc put(slots: var Slots, target: SwapTarget, player: string) =
  let first = target.position == 0
  case target.team
  of "A":
    if first: slots.a1 = player else: slots.a2 = player
  of "B":
    if first: slots.b1 = player else: slots.b2 = player
  else:
    discard

proc movePlayer(a, b: SwapTarget, same: bool, left, right: var GameContent): string =
  ## Both ids are read before either slot is written, so the same-game case is
  ## one row with its two columns exchanged.
  let playerA = left.slots.at(a)
  let playerB = (if same: left.slots.at(b) else: right.slots.at(b))
  if playerA.len == 0:
    return "player slot A not found"
  if playerB.len == 0:
    return "player slot B not found"
  if same and playerA == playerB:
    return "cannot swap the same player"
  left.slots.put(a, playerB)
  if same: left.slots.put(b, playerA) else: right.slots.put(b, playerA)
  ""

proc moveTeam(a, b: SwapTarget, same: bool, left, right: var GameContent): string =
  ## Across games v1 swaps the pair on one side letter (store/swap.go:294-326);
  ## inside one game it swaps the two whole sides (swapTeamSameGame).
  if same:
    if left.slots.a1.len == 0 or left.slots.a2.len == 0 or
       left.slots.b1.len == 0 or left.slots.b2.len == 0:
      return "team swap needs four players in the game"
    swap(left.slots.a1, left.slots.b1)
    swap(left.slots.a2, left.slots.b2)
    return ""
  for position in 0 .. 1:
    let playerA = left.slots.at(SwapTarget(team: a.team, position: position))
    let playerB = right.slots.at(SwapTarget(team: b.team, position: position))
    if playerA.len == 0 or playerB.len == 0:
      return "team swap needs two players per side"
    left.slots.put(SwapTarget(team: a.team, position: position), playerB)
    right.slots.put(SwapTarget(team: b.team, position: position), playerA)
  ""

proc sessionGuard(conn: DbConn, communityId, sessionId: string,
                  expectedVersion: int): SwapOutcome =
  ## The session row is the OCC unit: lock it, then reject a non-draft session
  ## or a stale If-Match before any game is read or written.
  let row = conn.queryOne(
    """select status, version from session.sessions
       where community_id = $1::uuid and id = $2::uuid
       for update""",
    @[textParam(communityId), textParam(sessionId)])
  if row.isNone:
    return SwapOutcome(status: swNotFound)
  let status = row.get.get("status")
  # store/swap.go:101-103 rejects anything but a draft, because a swap reshapes
  # a schedule that has not been approved yet.
  if status != "draft":
    return SwapOutcome(status: swLocked)
  let current = parseInt(row.get.get("version"))
  if current != expectedVersion:
    return SwapOutcome(status: swStale)
  SwapOutcome(status: swOk, version: current, sessionStatus: status)

proc readContent(conn: DbConn, communityId, sessionId: string,
                 target: SwapTarget): Option[GameContent] =
  let row = conn.queryOne(
    """select coalesce(side_a1::text, '') as a1,
              coalesce(side_a2::text, '') as a2,
              coalesce(side_b1::text, '') as b1,
              coalesce(side_b2::text, '') as b2,
              status
       from session.games
       where community_id = $1::uuid and session_id = $2::uuid
         and round_no = $3 and court_no = $4""",
    @[textParam(communityId), textParam(sessionId),
      intParam(target.slot.int64), intParam(target.court.int64)])
  if row.isNone:
    return none(GameContent)
  let game = row.get
  var content = GameContent(
    slots: Slots(a1: game.get("a1"), a2: game.get("a2"),
                 b1: game.get("b1"), b2: game.get("b2")),
    status: game.get("status"))
  for entry in conn.query(
    """select score_a, score_b from session.game_sets
       where community_id = $1::uuid and session_id = $2::uuid
         and round_no = $3 and court_no = $4
       order by set_no""",
    @[textParam(communityId), textParam(sessionId),
      intParam(target.slot.int64), intParam(target.court.int64)]):
    content.sets.add SetScore(a: parseInt(entry.get("score_a")),
      b: parseInt(entry.get("score_b")))
  some(content)

proc writeContent(conn: DbConn, communityId, sessionId: string,
                  target: SwapTarget, content: GameContent) =
  ## One statement per row, so the CHECK constraints see the final four slots
  ## together. The games trigger already bumps the row version and updated_at.
  ## The flat score columns are only the migration's backfill source: every
  ## write after 0029 leaves them empty and the sets are the result.
  discard conn.execUpdate(
    """update session.games set
         side_a1 = nullif($5, '')::uuid, side_a2 = nullif($6, '')::uuid,
         side_b1 = nullif($7, '')::uuid, side_b2 = nullif($8, '')::uuid,
         score_a = null, score_b = null, status = $9
       where community_id = $1::uuid and session_id = $2::uuid
         and round_no = $3 and court_no = $4""",
    @[textParam(communityId), textParam(sessionId),
      intParam(target.slot.int64), intParam(target.court.int64),
      textParam(content.slots.a1), textParam(content.slots.a2),
      textParam(content.slots.b1), textParam(content.slots.b2),
      textParam(content.status)])
  # Sets follow the payload. Deleting first also frees the (game, set_no) keys,
  # so a two-game swap can move a set list between slots without a collision.
  discard conn.execUpdate(
    """delete from session.game_sets
       where community_id = $1::uuid and session_id = $2::uuid
         and round_no = $3 and court_no = $4""",
    @[textParam(communityId), textParam(sessionId),
      intParam(target.slot.int64), intParam(target.court.int64)])
  for index, entry in content.sets:
    discard conn.execUpdate(
      """insert into session.game_sets
           (community_id, session_id, round_no, court_no, set_no, score_a, score_b)
         values ($1::uuid, $2::uuid, $3, $4, $5, $6, $7)""",
      @[textParam(communityId), textParam(sessionId),
        intParam(target.slot.int64), intParam(target.court.int64),
        intParam((index + 1).int64), intParam(entry.a.int64),
        intParam(entry.b.int64)])

proc isConstraintError(error: ref DbError): bool =
  ## SQLSTATE class 23 is an integrity violation. The v2 CHECK constraints make
  ## an impossible swap (one player twice in a game) a validation failure.
  error.sqlState.len >= 2 and error.sqlState[0 .. 1] == "23"

proc swapMembers*(db: Db, communityId, sessionId: string, expectedVersion: int,
                  patch: SwapPatch): SwapOutcome =
  ## Swaps one player, one team or two whole games, exactly like v1, and bumps
  ## the session version because the schedule changed. One transaction: the
  ## session row lock serialises this with every other schedule write.
  if patch.kind.isNone:
    return SwapOutcome(status: swInvalid, detail: patch.error)
  let kind = patch.kind.get
  let reason = swapError(kind, patch.a, patch.b)
  if reason.len > 0:
    return SwapOutcome(status: swInvalid, detail: reason)

  var outcome = SwapOutcome(status: swOk)
  try:
    discard db.tx(proc(conn: DbConn): int =
      let guard = sessionGuard(conn, communityId, sessionId, expectedVersion)
      if guard.status != swOk:
        outcome = guard
        return 0
      let a = patch.a
      let b = patch.b
      let same = a.slot == b.slot and a.court == b.court
      let first = readContent(conn, communityId, sessionId, a)
      let second = if same: first else: readContent(conn, communityId, sessionId, b)
      if first.isNone or second.isNone:
        # The session exists; it is the game the caller named that does not.
        outcome = SwapOutcome(status: swNotFound,
          detail: "swap target game not found")
        return 0
      var left = first.get
      var right = second.get
      var failure = ""
      case kind
      of skPlayer: failure = movePlayer(a, b, same, left, right)
      of skTeam: failure = moveTeam(a, b, same, left, right)
      of skSlot:
        # v2 keys a game by (session, round_no, court_no) and keeps its players
        # in the row, so the whole payload trades places. v1 moved the row
        # itself (swapSlots) and carried its child rows along; the payload a
        # client reads back is the same either way.
        swap(left, right)
      if failure.len > 0:
        outcome = SwapOutcome(status: swInvalid, detail: failure)
        return 0
      writeContent(conn, communityId, sessionId, a, left)
      if not same:
        writeContent(conn, communityId, sessionId, b, right)
      # A skip stays on the slot, so a swap can leave one naming a player who
      # moved away from that game.
      discard clearStaleSkips(conn, communityId, sessionId)
      discard conn.execUpdate(
        """update session.sessions set version = version + 1, updated_at = now()
           where community_id = $1::uuid and id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)])
      outcome = SwapOutcome(status: swOk, version: guard.version + 1,
                            sessionStatus: guard.sessionStatus)
      1)
  except DbError as error:
    if isConstraintError(error):
      return SwapOutcome(status: swInvalid,
        detail: "swap would put one player twice in a game")
    raise
  outcome
