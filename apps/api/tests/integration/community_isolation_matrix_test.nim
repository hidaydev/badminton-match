## The cross-community isolation matrix (DB-16 / ADR-018).
##
## One database holds two communities. A caller who is a member of community B
## calls every `/c/{slug}/...` operation with B's slug and an id that belongs to
## community A. Nothing of A's may come back, and nothing of A's may change.
##
## The operation list is not hand-kept: every contract route whose path carries
## `{slug}` is walked out of the generated table, and `probe` has to answer for
## each one. A route added to the contract without a probe fails this suite by
## default, which is the point: the matrix cannot silently fall behind the API.
##
## `knownRed` is the explicit list of operations that leak today, and it is
## empty: the routes were fixed before this suite merged. A route that starts
## leaking fails here. If one does leak, it goes on the list with a reason, is
## asserted to still leak, and the day it is fixed this suite fails and asks for
## its line to be removed.

import std/[json, options, strutils, unittest]
import db/db
import share/crypto
import share/store as shareStore
import tournament/domain/classic
import tournament/domain/classic_draw
import tests/fixtures
import ../../src/routes_gen
import ../http_support

const
  slugA = "iso-a-tenant"
  slugB = "iso-b-tenant"
  ## Two distinct substrings: every row of A carries `markerA`, every row this
  ## suite writes into B carries `markerB`. A response that carries `markerA`
  ## has read A from a B context, and a B write that carries `markerB` cannot be
  ## confused for one.
  markerA = "AA94MARK"
  markerB = "BB94MARK"
  ## Every answer a correctly scoped operation may give when it is handed a row
  ## it does not own. A 200 is never on this list: an empty envelope is a
  ## different shape.
  refusals = [400, 403, 404, 409, 412]

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)

type
  ProbeKind = enum
    pkSelfRead    ## reads only the caller's own community; must answer 200
                  ## without a byte of A
    pkSelfWrite   ## writes only the caller's own community: takes no foreign
                  ## id, so the fingerprint is what proves it landed in B
    pkForeign     ## names a row of A from B's prefix: must refuse

  Probe = object
    verb: HttpMethod
    path: string
    body: string
    ifMatch: string
    kind: ProbeKind

  Ids = object
    ## Every row of A the matrix points at, and the two rows of B a probe needs
    ## to be a legitimate request rather than a malformed one.
    memberUser: string
    player: string
    player2: string
    session: string
    claim: string
    joinRequest: string
    tournament: string
    matchKey: string
    event: string
    bPlayer: string

var
  database: Db
  ids: Ids
  aCommunityId, bCommunityId: string
  aCookie, bCookie: string

proc bootstrap() =
  database = openDb(dsn(), 1)
  purgeCommunity(database, slugA)
  purgeCommunity(database, slugB)
  cleanupUsers(database, "iso-a-%")
  cleanupUsers(database, "iso-b-%")

  let aAdmin = newUser(database, "iso-a-admin", "iso-a-admin@example.com",
    markerA & "-Admin")
  ids.memberUser = newUser(database, "iso-a-member",
    "iso-a-member@example.com", markerA & "-Member")
  aCommunityId = newCommunity(database, slugA, markerA & "-Club")
  newMember(database, aCommunityId, aAdmin, "admin")
  newMember(database, aCommunityId, ids.memberUser, "member")
  aCookie = cookieFor(database, aAdmin)

  ids.player = newPlayer(database, aCommunityId, markerA & "-Player")
  ids.player2 = newPlayer(database, aCommunityId, markerA & "-Player2")
  ids.session = newSession(database, aCommunityId, markerA & "-Night",
    sessionDate = "2026-11-18", status = "draft")
  newParticipant(database, aCommunityId, ids.session, ids.player)
  newParticipant(database, aCommunityId, ids.session, ids.player2)
  newGame(database, aCommunityId, ids.session, 0, 0, [ids.player],
    [ids.player2])
  ids.claim = newClaim(database, aCommunityId, ids.player, ids.memberUser)
  ids.joinRequest = newJoinRequest(database, aCommunityId, ids.memberUser)
  ids.tournament = database.queryOne(
    """insert into tournament.tournaments
         (community_id, name, status, format, event_date)
       values ($1::uuid, $2, 'draft', 'classic', '2026-11-18')
       returning id""",
    @[textParam(aCommunityId), textParam(markerA & "-Cup")]).get.getUuid("id")
  ids.matchKey = "AA94M1"
  discard database.execUpdate(
    """insert into tournament.matches
         (community_id, tournament_id, round_no, match_key, phase)
       values ($1::uuid, $2::uuid, 0, $3, 'group')""",
    @[textParam(aCommunityId), textParam(ids.tournament),
      textParam(ids.matchKey)])
  # One ledger event of A's, so the sign-off and revert routes have something
  # to reach for and the fingerprint notices if they touch it.
  ids.event = database.queryOne(
    """insert into rating.events (community_id, local_date, event_type)
       values ($1::uuid, '2026-11-18', 'session') returning id""",
    @[textParam(aCommunityId)]).get.getUuid("id")
  discard shareStore.issue(database, loadKeyring(keysJson, "1"), aCommunityId,
    ids.session, ids.memberUser, 30)

  let bAdmin = newUser(database, "iso-b-admin", "iso-b-admin@example.com",
    markerB & "-Admin")
  bCommunityId = newCommunity(database, slugB, markerB & "-Club")
  newMember(database, bCommunityId, bAdmin, "admin")
  ids.bPlayer = newPlayer(database, bCommunityId, markerB & "-Player")
  bCookie = cookieFor(database, bAdmin)
  # Multi-community: two communities are a supported production shape, so the
  # app boots with the plain fixture and the create route is expected to accept
  # a third one.
  startServer(newTestApp(database), port, baseUrl)

proc tournamentBody(): string =
  ## The create route validates the whole draw, so the smallest valid body is a
  ## complete 16-pair tournament from the product's own generator. A half-built
  ## body would be refused for its shape, and the probe would prove nothing.
  var pairs: seq[Pair] = @[]
  for index in 1 .. PairCount:
    pairs.add(Pair(id: "p" & $index,
      name: markerB & "-P" & $(index * 2 - 1) & " & P" & $(index * 2)))
  let data = generateTournament(markerB & "-Cup", "2026-11-20", pairs, 11)
  var pairNodes = newJArray()
  for pair in data.pairs:
    pairNodes.add(%*{"id": pair.id, "name": pair.name})
  var groups = newJObject()
  for groupId in GroupIds:
    var members = newJArray()
    for pairId in data.groups[ord(groupId)]:
      members.add(%pairId)
    groups[$groupId] = members
  var matches = newJArray()
  for match in data.matches:
    matches.add(%*{
      "id": match.id, "phase": $match.phase,
      "groupId": if match.groupId.isSome: %($match.groupId.get) else: newJNull(),
      "pairAId": if match.pairAId.isSome: %match.pairAId.get else: newJNull(),
      "pairBId": if match.pairBId.isSome: %match.pairBId.get else: newJNull(),
      "scoreA": if match.scoreA.isSome: %match.scoreA.get else: newJNull(),
      "scoreB": if match.scoreB.isSome: %match.scoreB.get else: newJNull()})
  $ %*{"name": data.name, "date": data.date, "pairs": pairNodes,
    "groups": groups, "matches": matches}

bootstrap()

proc probe(operationId: string): Probe =
  ## One line per operation the contract declares under `{slug}`. The body is
  ## the smallest valid one for that route, so a refusal is about the community
  ## and never about a malformed request.
  let claimed = """{"decision":"reject"}"""
  case operationId
  of "listPendingClaims":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/claims", kind: pkSelfRead)
  of "getCommunityConfig":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/config", kind: pkSelfRead)
  of "createInvite":
    Probe(verb: HttpPost, path: "/c/" & slugB & "/invites",
      body: """{"email":"iso-b-invite@example.com","role":"member"}""",
      kind: pkSelfWrite)
  of "listJoinRequests":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/join-requests",
      kind: pkSelfRead)
  of "createJoinRequest":
    Probe(verb: HttpPost, path: "/c/" & slugB & "/join-requests",
      body: "{}", kind: pkSelfWrite)
  of "decideJoinRequest":
    Probe(verb: HttpPatch,
      path: "/c/" & slugB & "/join-requests/" & ids.joinRequest,
      body: """{"decision":"approve"}""", kind: pkForeign)
  of "listMembers":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/members", kind: pkSelfRead)
  of "removeMember":
    Probe(verb: HttpDelete, path: "/c/" & slugB & "/members/" & ids.memberUser,
      kind: pkForeign)
  of "patchMemberRole":
    Probe(verb: HttpPatch, path: "/c/" & slugB & "/members/" & ids.memberUser,
      body: """{"role":"host"}""", kind: pkForeign)
  of "listPlayers":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/players", kind: pkSelfRead)
  of "createPlayer":
    Probe(verb: HttpPost, path: "/c/" & slugB & "/players",
      body: "{\"name\":\"" & markerB & "-New\"}", kind: pkSelfWrite)
  of "deletePlayer":
    Probe(verb: HttpDelete, path: "/c/" & slugB & "/players/" & ids.player,
      kind: pkForeign)
  of "getPlayer":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/players/" & ids.player,
      kind: pkForeign)
  of "patchPlayer":
    Probe(verb: HttpPatch, path: "/c/" & slugB & "/players/" & ids.player,
      body: "{\"name\":\"" & markerA & "-Stolen\"}", kind: pkForeign)
  of "getPlayerAchievements":
    Probe(verb: HttpGet,
      path: "/c/" & slugB & "/players/" & ids.player & "/achievements",
      kind: pkForeign)
  of "deleteOwnClaim":
    Probe(verb: HttpDelete,
      path: "/c/" & slugB & "/players/" & ids.player & "/claim",
      kind: pkForeign)
  of "listPlayerClaims":
    Probe(verb: HttpGet,
      path: "/c/" & slugB & "/players/" & ids.player & "/claims",
      kind: pkForeign)
  of "postPlayerClaim":
    Probe(verb: HttpPost,
      path: "/c/" & slugB & "/players/" & ids.player & "/claims",
      kind: pkForeign)
  of "patchPlayerClaim":
    Probe(verb: HttpPatch,
      path: "/c/" & slugB & "/players/" & ids.player & "/claims/" & ids.claim,
      body: claimed, kind: pkForeign)
  of "postPlayerMerge":
    # B's own player as the target, A's player as the source: a merge that read
    # the source without its community would fold A's rows into B.
    Probe(verb: HttpPost,
      path: "/c/" & slugB & "/players/" & ids.bPlayer & "/merge",
      body: "{\"sourcePlayerId\":\"" & ids.player & "\"}", kind: pkForeign)
  of "getPlayerStats":
    Probe(verb: HttpGet,
      path: "/c/" & slugB & "/players/" & ids.player & "/stats",
      kind: pkForeign)
  of "listRankings":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/rankings", kind: pkSelfRead)
  of "getRanking":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/rankings/" & ids.player,
      kind: pkForeign)
  of "listRatingSources":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/rating-sources",
      kind: pkSelfRead)
  of "deleteRatingSource":
    Probe(verb: HttpDelete,
      path: "/c/" & slugB & "/rating-sources/" & ids.event, kind: pkForeign)
  of "patchRatingSource":
    Probe(verb: HttpPatch,
      path: "/c/" & slugB & "/rating-sources/" & ids.event,
      body: """{"finalized":true}""", kind: pkForeign)
  of "postRatingsRebuild":
    Probe(verb: HttpPost, path: "/c/" & slugB & "/ratings/rebuild",
      kind: pkSelfWrite)
  of "listSessions":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/sessions", kind: pkSelfRead)
  of "createSession":
    Probe(verb: HttpPost, path: "/c/" & slugB & "/sessions",
      body: "{\"title\":\"" & markerB & "-Night\"," &
        "\"date\":\"2026-11-20\",\"startTime\":\"18:00\"}",
      kind: pkSelfWrite)
  of "deleteSession":
    Probe(verb: HttpDelete, path: "/c/" & slugB & "/sessions/" & ids.session,
      kind: pkForeign)
  of "getSession":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/sessions/" & ids.session,
      kind: pkForeign)
  of "patchSession":
    Probe(verb: HttpPatch, path: "/c/" & slugB & "/sessions/" & ids.session,
      body: "{\"title\":\"" & markerA & "-Stolen\"}", ifMatch: "1",
      kind: pkForeign)
  of "patchSessionAbsent":
    Probe(verb: HttpPatch,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/absent",
      body: "{\"playerIds\":[]}", ifMatch: "1", kind: pkForeign)
  of "getSessionGame":
    Probe(verb: HttpGet,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/games/0-0",
      kind: pkForeign)
  of "patchSessionGame":
    Probe(verb: HttpPatch,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/games/0-0",
      body: """{"played":true}""", ifMatch: "1", kind: pkForeign)
  of "skipSessionGame":
    Probe(verb: HttpPatch,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/games/0-0/skip",
      body: "{\"playerIds\":[]}", ifMatch: "1", kind: pkForeign)
  of "lockSession":
    Probe(verb: HttpPost,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/lock",
      ifMatch: "1", kind: pkForeign)
  of "unlockSession":
    Probe(verb: HttpPost,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/unlock",
      ifMatch: "1", kind: pkForeign)
  of "deleteSessionRating":
    Probe(verb: HttpDelete,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/rating",
      kind: pkForeign)
  of "postSessionRating":
    Probe(verb: HttpPost,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/rating",
      kind: pkForeign)
  of "putSessionSchedule":
    Probe(verb: HttpPut,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/schedule",
      body: """{"games":[]}""", ifMatch: "1", kind: pkForeign)
  of "deleteShareLink":
    Probe(verb: HttpDelete,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/share",
      kind: pkForeign)
  of "getShareLink":
    Probe(verb: HttpGet,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/share",
      kind: pkForeign)
  of "createShareLink":
    Probe(verb: HttpPost,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/share",
      kind: pkForeign)
  of "getSessionStandings":
    Probe(verb: HttpGet,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/standings",
      kind: pkForeign)
  of "postSessionSwap":
    Probe(verb: HttpPost,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/swap",
      body: """{"type":"slot","a":{"slot":0,"court":0},"b":{"slot":0,"court":1}}""",
      ifMatch: "1", kind: pkForeign)
  of "postSessionWsTicket":
    Probe(verb: HttpPost,
      path: "/c/" & slugB & "/sessions/" & ids.session & "/ws-ticket",
      kind: pkForeign)
  of "getSettings":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/settings", kind: pkSelfRead)
  of "patchSettings":
    Probe(verb: HttpPatch, path: "/c/" & slugB & "/settings",
      body: """{"community.invite_ttl_days":7}""", kind: pkSelfWrite)
  of "listTournaments":
    Probe(verb: HttpGet, path: "/c/" & slugB & "/tournaments",
      kind: pkSelfRead)
  of "createTournament":
    Probe(verb: HttpPost, path: "/c/" & slugB & "/tournaments",
      body: tournamentBody(), kind: pkSelfWrite)
  of "deleteTournament":
    Probe(verb: HttpDelete,
      path: "/c/" & slugB & "/tournaments/" & ids.tournament, kind: pkForeign)
  of "getTournament":
    Probe(verb: HttpGet,
      path: "/c/" & slugB & "/tournaments/" & ids.tournament, kind: pkForeign)
  of "putTournament":
    Probe(verb: HttpPut,
      path: "/c/" & slugB & "/tournaments/" & ids.tournament,
      body: "{\"format\":\"classic\",\"name\":\"" & markerA & "-Stolen\"," &
        "\"date\":\"2026-11-20\"}",
      ifMatch: "1", kind: pkForeign)
  of "patchTournamentMatch":
    Probe(verb: HttpPatch,
      path: "/c/" & slugB & "/tournaments/" & ids.tournament & "/matches/" &
        ids.matchKey,
      body: """{"scoreA":21,"scoreB":19}""", ifMatch: "1", kind: pkForeign)
  of "deleteTournamentRating":
    Probe(verb: HttpDelete,
      path: "/c/" & slugB & "/tournaments/" & ids.tournament & "/rating",
      kind: pkForeign)
  of "postTournamentRating":
    Probe(verb: HttpPost,
      path: "/c/" & slugB & "/tournaments/" & ids.tournament & "/rating",
      kind: pkForeign)
  of "wsSession":
    # The handshake names a community and a session. A ticket for A's session
    # under B's slug has to be refused before the socket upgrades, so a plain
    # GET answers here and the refusal is the assertion.
    Probe(verb: HttpGet,
      path: "/ws/c/" & slugB & "/sessions/" & ids.session, kind: pkForeign)
  else:
    raise newException(ValueError,
      "no isolation probe for " & operationId & ": add one to `probe`")

proc fingerprint(communityId: string): string =
  ## Every table that carries a `community_id`, counted for one community. A
  ## route that writes a row of the other community moves one of these numbers,
  ## and the catalog is read rather than a hand-kept list, so a new table is
  ## covered the day it ships.
  var parts: seq[string] = @[]
  for row in database.query(
    """select c.table_schema || '.' || c.table_name as rel
       from information_schema.columns c
       join information_schema.tables t
         on t.table_schema = c.table_schema and t.table_name = c.table_name
       where c.column_name = 'community_id'
         and t.table_type = 'BASE TABLE'
         and c.table_schema not in ('pg_catalog', 'information_schema')
       order by 1"""):
    let relation = row.get("rel")
    let count = database.queryOne(
      "select count(*)::int as n from " & relation &
        " where community_id = $1::uuid",
      @[textParam(communityId)]).get.get("n")
    if count != "0":
      parts.add(relation & "=" & count)
  parts.join(",")

suite "community isolation matrix":
  test "every contract route under {slug} has a probe":
    var covered = 0
    var misrouted: seq[string] = @[]
    for spec in routes:
      if not spec.path.contains("{slug}"):
        continue
      let p = probe(spec.operationId)
      covered += 1
      if not (p.path.startsWith("/c/" & slugB & "/") or
          p.path.startsWith("/ws/c/" & slugB & "/")):
        misrouted.add(spec.operationId & " probes " & p.path)
    # A probe that names any other prefix would test a route the caller can
    # already read, so the whole matrix would prove nothing about B.
    checkpoint(misrouted.join("\n"))
    check misrouted.len == 0
    # A contract with no scoped route would make the walk below vacuous.
    check covered > 40

  test "community B never reads or writes community A":
    let before = fingerprint(aCommunityId)
    var leaked: seq[string] = @[]
    var details: seq[string] = @[]
    # The control: the same read against A's own slug, as an A admin, must
    # carry markerA. Without it, a marker that never reaches a body would
    # report a green matrix over an API that answers nothing at all.
    let control = call(baseUrl, HttpGet, "/c/" & slugA & "/players", aCookie)
    expectStatus(control, 200)
    checkpoint("control body: " & control.body)
    check markerA in control.body

    for spec in routes:
      if not spec.path.contains("{slug}"):
        continue
      let p = probe(spec.operationId)
      let response = call(baseUrl, p.verb, p.path, bCookie, p.body,
        ifMatch = p.ifMatch)
      var verdict = ""
      if markerA in response.body:
        verdict = "answered with " & spec.operationId & "'s " & "data of A (" &
          $response.status & ")"
      elif p.kind == pkSelfRead and response.status != 200:
        verdict = "expected a 200 envelope, got " & $response.status &
          " " & response.body
      elif p.kind == pkForeign and response.status notin refusals:
        verdict = "accepted a row of A: " & $response.status & " " & response.body
      let after = fingerprint(aCommunityId)
      if after != before:
        verdict = "changed community A's rows: " & before & " -> " & after
      if verdict.len > 0:
        leaked.add(spec.operationId)
        details.add(spec.operationId & ": " & verdict)
    discard control

    if leaked.len > 0:
      echo "isolation RED list ("
      for line in details:
        echo "  " & line
      echo ")"
    checkpoint(details.join("\n"))
    # Empty today: every scoped route answered for B without touching A. A route
    # that starts leaking has to be named here with its reason, so the list says
    # out loud what is still broken instead of hiding it in a comment.
    const knownRed: seq[string] = @[]
    check leaked == knownRed

    # The self-writes must have landed in B, or `pkSelfWrite` proves nothing.
    check database.queryOne(
      """select count(*)::int as n from community.invite
         where community_id = $1::uuid""",
      @[textParam(bCommunityId)]).get.get("n") == "1"
    check database.queryOne(
      """select count(*)::int as n from player.players
         where community_id = $1::uuid and canonical_name = $2""",
      @[textParam(bCommunityId), textParam(markerB & "-New")]).get.get("n") == "1"
    check database.queryOne(
      """select count(*)::int as n from session.sessions
         where community_id = $1::uuid and title = $2""",
      @[textParam(bCommunityId), textParam(markerB & "-Night")]).get.get("n") == "1"
    check database.queryOne(
      """select count(*)::int as n from tournament.tournaments
         where community_id = $1::uuid and name = $2""",
      @[textParam(bCommunityId), textParam(markerB & "-Cup")]).get.get("n") == "1"

  test "the create-community route writes a second community that reads nothing of A":
    ## `POST /communities` is the one write with no `{slug}`, so the matrix
    ## above cannot reach it. Multi-community in one database is the product's
    ## headline feature: the route writes the row, and the community it creates
    ## starts empty instead of inheriting a neighbour's data.
    let aPrint = fingerprint(aCommunityId)
    let ownerUser = newUser(database, "iso-a-owner",
      "iso-a-owner@example.com", markerA & "-Owner", owner = true)
    let ownerCookie = cookieFor(database, ownerUser)
    let before = database.queryOne(
      "select count(*)::int as n from platform.community").get.get("n")
    let created = call(baseUrl, HttpPost, "/communities", ownerCookie,
      """{"slug":"iso-a-second-door","name":"Second","adminEmail":"second@example.com"}""")
    checkpoint("POST /communities: " & $created.status & " " & created.body)
    expectStatus(created, 201)
    let secondId = parseJson(created.body)["id"].getStr()
    let after = database.queryOne(
      "select count(*)::int as n from platform.community").get.get("n")
    check after == $((parseInt(before)) + 1)
    check database.queryOne(
      "select 1 as one from platform.community where slug = 'iso-a-second-door'")
      .isSome

    # A session scoped to the new community reads nothing of A.
    let secondAdmin = newUser(database, "iso-a-owner-second",
      "iso-a-owner-second@example.com", markerA & "-Second Admin")
    newMember(database, secondId, secondAdmin, "admin")
    let secondCookie = cookieFor(database, secondAdmin)
    let ownPlayers = call(baseUrl, HttpGet, "/c/iso-a-second-door/players",
      secondCookie)
    expectStatus(ownPlayers, 200)
    check markerA notin ownPlayers.body
    let foreignSession = call(baseUrl, HttpGet,
      "/c/iso-a-second-door/sessions/" & ids.session, secondCookie)
    check foreignSession.status in refusals
    check markerA notin foreignSession.body
    # Nothing of A's moved while that happened.
    check fingerprint(aCommunityId) == aPrint
    purgeCommunity(database, "iso-a-second-door")
    cleanupUsers(database, "iso-a-owner")

  test "community A still holds every row the matrix pointed at":
    ## A refusal that deletes or clears the row it was refused is not a refusal.
    check database.queryOne(
      "select canonical_name from player.players where community_id = $1::uuid and id = $2::uuid",
      @[textParam(aCommunityId), textParam(ids.player)]).get.get("canonical_name") ==
      markerA & "-Player"
    check database.queryOne(
      "select title from session.sessions where community_id = $1::uuid and id = $2::uuid",
      @[textParam(aCommunityId), textParam(ids.session)]).get.get("title") ==
      markerA & "-Night"
    check database.queryOne(
      "select name from tournament.tournaments where community_id = $1::uuid and id = $2::uuid",
      @[textParam(aCommunityId), textParam(ids.tournament)]).get.get("name") ==
      markerA & "-Cup"
    check database.queryOne(
      """select status from player.claims
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(aCommunityId), textParam(ids.claim)]).get.get("status") ==
      "pending"
    check database.queryOne(
      """select role from community.membership
         where community_id = $1::uuid and user_id = $2::uuid""",
      @[textParam(aCommunityId), textParam(ids.memberUser)]).get.get("role") ==
      "member"
    check database.queryOne(
      """select count(*)::int as n from session.links
         where community_id = $1::uuid""",
      @[textParam(aCommunityId)]).get.get("n") == "1"
    check database.queryOne(
      """select count(*)::int as n from rating.sources
         where community_id = $1::uuid""",
      @[textParam(aCommunityId)]).get.get("n") == "0"
    waitForRatingJobs()
    database.close()
