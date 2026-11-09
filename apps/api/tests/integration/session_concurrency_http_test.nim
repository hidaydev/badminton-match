## BE-08: two writers against one row at the HTTP surface.
##
## Every existing OCC case drives one writer at a time, so a read followed by an
## unversioned update would pass them. Each case here opens two threads, holds
## both at a channel barrier until each is ready, releases them together, sends
## exactly one request per thread and then joins. Nothing is retried and nothing
## sleeps: the assertions are the invariant after the race plus the proof that
## exactly one of the two outcomes happened.

import std/[json, options, sequtils, unittest]
import db/db
import tournament/domain/classic
import tournament/domain/classic_draw
import tests/fixtures
import ../http_support

let
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  slug = "be08-occ"
  hostEmail = "be08-occ-host@example.com"

type
  HttpJob = object
    ## One request and its answer. The thread fills `response`; the suite reads
    ## it only after `joinThread`.
    verb: HttpMethod
    path, cookie, body, ifMatch: string
    extra: seq[(string, string)]
    response: HttpResult

var
  database, serverDb: Db
  communityId, hostId: string
  hostCookie: string
  players: seq[string]
  # The barrier. An unbuffered channel makes each `send` wait for a receiver,
  # so both threads have reached `recv` before either request is issued.
  ready: Channel[bool]
  start: Channel[bool]

proc writer(job: ptr HttpJob) {.thread.} =
  {.cast(gcsafe).}:
    ready.send(true)
    discard start.recv()
    job.response = call(baseUrl, job.verb, job.path, job.cookie, job.body,
      ifMatch = job.ifMatch, extra = job.extra)

proc race(first, second: var HttpJob) =
  ## Starts both jobs together and returns once both requests have finished.
  open(ready)
  open(start)
  var firstThread: Thread[ptr HttpJob]
  var secondThread: Thread[ptr HttpJob]
  createThread(firstThread, writer, addr first)
  createThread(secondThread, writer, addr second)
  discard ready.recv()
  discard ready.recv()
  start.send(true)
  start.send(true)
  joinThread(firstThread)
  joinThread(secondThread)
  close(ready)
  close(start)

proc classicBody(name: string): string =
  ## A valid 16-pair draw from the product's own generator. Only `name` differs
  ## between the two racing bodies, so the stored name says which one landed.
  var pairs: seq[Pair] = @[]
  for index in 1 .. 16:
    pairs.add(Pair(id: "p" & $index,
      name: "Player " & $(index * 2 - 1) & " & Player " & $(index * 2)))
  let data = generateTournament(name, "2026-11-10", pairs, 11)
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

proc slotOf(sessionId: string, court: int, column: string): string =
  ## One stored side column of one game, so a case can read what the winner
  ## really wrote instead of trusting the response body.
  let row = database.queryOne(
    """select coalesce(""" & column & """::text, '') as value
       from session.games
       where community_id = $1::uuid and session_id = $2::uuid
         and round_no = 0 and court_no = $3""",
    @[textParam(communityId), textParam(sessionId), intParam(court.int64)]).get
  row.get("value")

proc bootstrap() =
  database = openDb(dsn(), 1)
  purgeCommunity(database, slug)
  cleanupUsers(database, "be08-occ-%")
  communityId = newCommunity(database, slug, "BE08 OCC")
  hostId = newUser(database, "be08-occ-host", hostEmail, "BE08 Host")
  newMember(database, communityId, hostId, "host")
  hostCookie = cookieFor(database, hostId)
  for name in ["Ani", "Budi", "Cakra", "Dewi", "Eka", "Fajar", "Gita", "Hadi"]:
    players.add(newPlayer(database, communityId, name))
  # The app gets a pool of four, not the pool of one the other suites use: a
  # race needs two requests to hold a connection at the same time.
  serverDb = openDb(dsn(), 4)
  startServer(newTestApp(serverDb), port, baseUrl)

bootstrap()

suite "session concurrency HTTP":
  test "two hosts patching from one version keep exactly one title":
    let created = call(baseUrl, HttpPost, "/c/" & slug & "/sessions",
      hostCookie, """{"title":"Patch race","date":"2026-11-08"}""")
    expectStatus(created, 201)
    let sessionId = parseJson(created.body)["id"].getStr()
    let path = "/c/" & slug & "/sessions/" & sessionId
    var first = HttpJob(verb: HttpPatch, path: path, cookie: hostCookie,
      body: """{"title":"Patch race A"}""", ifMatch: "\"1\"")
    var second = HttpJob(verb: HttpPatch, path: path, cookie: hostCookie,
      body: """{"title":"Patch race B"}""", ifMatch: "\"1\"")
    race(first, second)

    let statuses = @[first.response.status, second.response.status]
    check statuses.count(200) == 1
    check statuses.count(412) == 1
    let winner = if first.response.status == 200: first else: second
    let loser = if first.response.status == 412: first else: second
    check parseJson(loser.response.body)["code"].getStr() == "STALE_VERSION"
    let stored = database.queryOne(
      """select title, version from session.sessions where id = $1::uuid""",
      @[textParam(sessionId)]).get
    # One versioned update landed: the title is the winner's and the version
    # moved once, so the loser's body reached no column.
    check stored.get("version") == "2"
    check stored.get("title") == parseJson(winner.response.body)["title"].getStr()
    check stored.get("title") ==
      (if first.response.status == 200: "Patch race A" else: "Patch race B")

  test "two hosts swapping from one version apply exactly one swap":
    let created = call(baseUrl, HttpPost, "/c/" & slug & "/sessions",
      hostCookie, """{"title":"Swap race","date":"2026-11-08"}""")
    expectStatus(created, 201)
    let sessionId = parseJson(created.body)["id"].getStr()
    let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
      players[0] & """","""" & players[1] & """"],"sideB":["""" &
      players[2] & """","""" & players[3] & """"]},
      {"round":0,"court":1,"sideA":["""" & players[4] & """","""" &
      players[5] & """"],"sideB":["""" & players[6] & """","""" &
      players[7] & """"]}]}"""
    let written = call(baseUrl, HttpPut,
      "/c/" & slug & "/sessions/" & sessionId & "/schedule", hostCookie,
      schedule, ifMatch = "\"1\"")
    expectStatus(written, 200)
    let swapPath = "/c/" & slug & "/sessions/" & sessionId & "/swap"
    let swapBody = """{"type":"player","a":{"slot":0,"court":0,"team":"A","position":0},"b":{"slot":0,"court":1,"team":"A","position":0}}"""
    var first = HttpJob(verb: HttpPost, path: swapPath, cookie: hostCookie,
      body: swapBody, ifMatch: "\"2\"")
    var second = HttpJob(verb: HttpPost, path: swapPath, cookie: hostCookie,
      body: swapBody, ifMatch: "\"2\"")
    race(first, second)

    let statuses = @[first.response.status, second.response.status]
    check statuses.count(200) == 1
    check statuses.count(412) == 1
    let winner = if first.response.status == 200: first else: second
    let loser = if first.response.status == 412: first else: second
    expectStatus(winner.response, 200)
    check parseJson(winner.response.body)["version"].getInt() == 3
    check parseJson(loser.response.body)["code"].getStr() == "STALE_VERSION"
    # One swap applied, not two: a second application would put every player
    # back where the schedule left them. The stored version proves one bump.
    check slotOf(sessionId, 0, "side_a1") == players[4]
    check slotOf(sessionId, 1, "side_a1") == players[0]
    let session = database.queryOne(
      """select version from session.sessions where id = $1::uuid""",
      @[textParam(sessionId)]).get
    check session.get("version") == "3"

  test "two parallel creates with one key and one body leave one row":
    let createBody = """{"title":"BE08 one body","date":"2026-11-09"}"""
    let extra = @[("Idempotency-Key", "be08-same-body")]
    var first = HttpJob(verb: HttpPost, path: "/c/" & slug & "/sessions",
      cookie: hostCookie, body: createBody, extra: extra)
    var second = HttpJob(verb: HttpPost, path: "/c/" & slug & "/sessions",
      cookie: hostCookie, body: createBody, extra: extra)
    race(first, second)

    let statuses = @[first.response.status, second.response.status]
    # The loser either replays the stored 201 or is refused while the winner is
    # still in flight: `modules/platform/idempotency.nim:61-63` answers a
    # claimed-but-incomplete row with a conflict instead of a replay. Both are
    # that file's contract, so the invariant is what the case asserts.
    check statuses.count(201) + statuses.count(409) == 2
    check statuses.count(201) >= 1
    var createdIds: seq[string] = @[]
    for job in [first, second]:
      let body = parseJson(job.response.body)
      if job.response.status == 409:
        check body["code"].getStr() == "IDEMPOTENCY_CONFLICT"
      else:
        check job.response.status == 201
        createdIds.add(body["id"].getStr())
    check createdIds.len == statuses.count(201)
    if createdIds.len > 0:
      for id in createdIds:
        check id == createdIds[0]
    let rows = database.queryOne(
      """select count(*)::int as n from session.sessions
         where community_id = $1::uuid and title = 'BE08 one body'""",
      @[textParam(communityId)]).get
    check rows.get("n") == "1"

  test "two parallel creates with one key and two bodies write the winner only":
    let extra = @[("Idempotency-Key", "be08-two-bodies")]
    var first = HttpJob(verb: HttpPost, path: "/c/" & slug & "/sessions",
      cookie: hostCookie, body: """{"title":"BE08 body A","date":"2026-11-09"}""",
      extra: extra)
    var second = HttpJob(verb: HttpPost, path: "/c/" & slug & "/sessions",
      cookie: hostCookie, body: """{"title":"BE08 body B","date":"2026-11-09"}""",
      extra: extra)
    race(first, second)

    let statuses = @[first.response.status, second.response.status]
    # Different digests cannot replay or wait for each other: one insert claims
    # the key, so the other is a conflict whatever the order.
    check statuses.count(201) == 1
    check statuses.count(409) == 1
    let winner = if first.response.status == 201: first else: second
    let loser = if first.response.status == 409: first else: second
    check parseJson(loser.response.body)["code"].getStr() ==
      "IDEMPOTENCY_CONFLICT"
    let stored = database.queryOne(
      """select count(*)::int as n, max(title) as title from session.sessions
         where community_id = $1::uuid
           and title in ('BE08 body A', 'BE08 body B')""",
      @[textParam(communityId)]).get
    check stored.get("n") == "1"
    check stored.get("title") == parseJson(winner.response.body)["title"].getStr()

  test "two admins replacing one tournament from one version keep one body":
    let created = call(baseUrl, HttpPost, "/c/" & slug & "/tournaments",
      hostCookie, classicBody("BE08 Cup"))
    expectStatus(created, 201)
    let tournamentId = parseJson(created.body)["id"].getStr()
    let path = "/c/" & slug & "/tournaments/" & tournamentId
    var first = HttpJob(verb: HttpPut, path: path, cookie: hostCookie,
      body: classicBody("BE08 Cup A"), ifMatch: "\"1\"")
    var second = HttpJob(verb: HttpPut, path: path, cookie: hostCookie,
      body: classicBody("BE08 Cup B"), ifMatch: "\"1\"")
    race(first, second)

    let statuses = @[first.response.status, second.response.status]
    check statuses.count(200) == 1
    check statuses.count(412) == 1
    let winner = if first.response.status == 200: first else: second
    let loser = if first.response.status == 412: first else: second
    check parseJson(loser.response.body)["code"].getStr() == "STALE_VERSION"
    let stored = database.queryOne(
      """select name, version from tournament.tournaments
         where community_id = $1::uuid and id = $2::uuid""",
      @[textParam(communityId), textParam(tournamentId)]).get
    # The stored snapshot is exactly the winner's body at one bump: the loser's
    # replace neither changed the header nor replaced the children.
    check stored.get("version") == "2"
    check stored.get("name") ==
      (if first.response.status == 200: "BE08 Cup A" else: "BE08 Cup B")
    check parseJson(winner.response.body)["name"].getStr() == stored.get("name")
    let pairs = database.queryOne(
      """select count(*)::int as n from tournament.pairs
         where community_id = $1::uuid and tournament_id = $2::uuid""",
      @[textParam(communityId), textParam(tournamentId)]).get
    check pairs.get("n") == "16"

purgeCommunity(database, slug)
cleanupUsers(database, "be08-occ-%")
database.close()
serverDb.close()