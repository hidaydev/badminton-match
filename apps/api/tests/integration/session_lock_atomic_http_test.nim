## BE-10: locking a session and the rating it triggers are one transaction.
##
## The approval flag is the rating gate, so a session that is locked without a
## ledger event, or an event without the flag, is the inconsistency the rest of
## the design works to prevent. The suite injects a fault inside the ingest step
## and reads back the three artefacts: the status, the event and the audit row.

import std/[json, options, strutils, unittest]
import db/db
import community/infrastructure/community_store
import tests/fixtures
import ../http_support

const
  port = testPort()
  baseUrl = "http://127.0.0.1:" & $uint16(port)
  slug = "lock-atomic-club"
  adminEmail = "lock-atomic-admin@example.com"
  hostEmail = "lock-atomic-host@example.com"

var
  database: Db
  communityId: string
  hostCookie: string
  players: seq[string]

proc bootstrap() =
  database = openDb(dsn(), 2)
  purgeCommunity(database, slug)
  discard database.execUpdate(
    """delete from platform.idempotency_keys where user_id in
         (select id from platform.user where google_sub like 'lock-atomic-%')""")
  discard database.execUpdate(
    "delete from platform.user where google_sub like 'lock-atomic-%'")
  let ownerId = newUser(database, "lock-atomic-owner", adminEmail, "Owner",
    owner = true)
  communityId = community_store.create(database, slug, "Lock Atomic Club",
    adminEmail, "Asia/Jakarta", ownerId).communityId
  let hostId = newUser(database, "lock-atomic-host", hostEmail, "Host")
  newMember(database, communityId, hostId, "host")
  hostCookie = cookieFor(database, hostId)
  for name in ["Ani", "Budi", "Cakra", "Dewi"]:
    players.add(newPlayer(database, communityId, name))
  startServer(newTestApp(database), port, baseUrl)

proc scheduledSession(title: string): string =
  ## A draft with one scored game: the shape a host locks.
  let created = call(baseUrl, HttpPost, "/c/" & slug & "/sessions", hostCookie,
    """{"title":"""" & title & """","date":"2026-11-09"}""")
  expectStatus(created, 201)
  result = parseJson(created.body)["id"].getStr()
  let schedule = """{"games":[{"round":0,"court":0,"sideA":["""" &
    players[0] & """","""" & players[1] & """"],"sideB":["""" & players[2] &
    """","""" & players[3] & """"]}]}"""
  expectStatus(call(baseUrl, HttpPut,
    "/c/" & slug & "/sessions/" & result & "/schedule", hostCookie, schedule,
    ifMatch = "\"1\""), 200)
  expectStatus(call(baseUrl, HttpPatch,
    "/c/" & slug & "/sessions/" & result & "/games/0-0", hostCookie,
    """{"scoreA":30,"scoreB":15}""", ifMatch = "\"2\""), 200)

proc artefacts(sessionId: string): tuple[status: string, events: int,
                                         audits: int] =
  let row = database.queryOne(
    """select status from session.sessions
       where community_id = $1::uuid and id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)])
  let event = database.queryOne(
    """select count(*)::int as n from rating.events
       where community_id = $1::uuid and source_id = $2::uuid""",
    @[textParam(communityId), textParam(sessionId)])
  let audit = database.queryOne(
    """select count(*)::int as n from account.audit
       where community_id = $1::uuid and action = 'session.lock'
         and target_id = $2""",
    @[textParam(communityId), textParam(sessionId)])
  (status: row.get.get("status"),
   events: parseInt(event.get.get("n")),
   audits: parseInt(audit.get.get("n")))

proc injectIngestFault() =
  ## A before-insert fault on the counter table: the event row was already
  ## written, so a rollback that leaves no event proves the boundary covers it.
  discard database.execUpdate(
    """create or replace function lock_atomic_fault() returns trigger
       language plpgsql as $$
       begin
         raise exception 'injected ingest fault';
       end $$""")
  discard database.execUpdate(
    """create trigger lock_atomic_fault before insert on rating.player_state
       for each row execute function lock_atomic_fault()""")

proc dropIngestFault() =
  discard database.execUpdate(
    "drop trigger if exists lock_atomic_fault on rating.player_state")
  discard database.execUpdate("drop function if exists lock_atomic_fault()")

if dsn().len == 0:
  echo "SKIP session lock atomicity (MAJADU_PG_DSN is not set)"
else:
  bootstrap()

  suite "session lock is atomic with its rating":
    test "a fault in the ingest leaves the status, the event and no audit row":
      let sessionId = scheduledSession("Faulted lock")
      injectIngestFault()
      let locked = call(baseUrl, HttpPost,
        "/c/" & slug & "/sessions/" & sessionId & "/lock", hostCookie,
        ifMatch = "\"3\"")
      dropIngestFault()
      # The route reports the failure instead of a success it did not reach.
      check locked.status >= 500
      let after = artefacts(sessionId)
      check after.status == "draft"
      check after.events == 0
      check after.audits == 0
      # The row was not even versioned: nothing of the lock survived.
      let version = database.queryOne(
        """select version from session.sessions
           where community_id = $1::uuid and id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)])
      check version.get.get("version") == "3"

    test "a successful lock writes the status, the event and one audit row":
      let sessionId = scheduledSession("Atomic lock")
      let locked = call(baseUrl, HttpPost,
        "/c/" & slug & "/sessions/" & sessionId & "/lock", hostCookie,
        ifMatch = "\"3\"")
      expectStatus(locked, 200)
      let after = artefacts(sessionId)
      check after.status == "locked"
      check after.events == 1
      check after.audits == 1
      # The status and its evidence were written on one connection: PostgreSQL
      # stamps every row with the id of the transaction that produced it. (The
      # ingest runs in a savepoint of that same transaction, which is why the
      # event row carries the subtransaction's id and is not compared here.)
      let sessionXmin = database.queryOne(
        """select xmin::text as x from session.sessions
           where community_id = $1::uuid and id = $2::uuid""",
        @[textParam(communityId), textParam(sessionId)]).get.get("x")
      let auditXmin = database.queryOne(
        """select xmin::text as x from account.audit
           where community_id = $1::uuid and action = 'session.lock'
             and target_id = $2""",
        @[textParam(communityId), textParam(sessionId)]).get.get("x")
      check auditXmin == sessionXmin

    test "a fault in the audit rolls the status and the event back":
      ## The other direction of the boundary: if the evidence cannot be
      ## written, the write it describes must not land either, which is only
      ## true when all three share one transaction.
      let sessionId = scheduledSession("Faulted audit")
      discard database.execUpdate(
        """create or replace function lock_atomic_audit_fault() returns trigger
           language plpgsql as $$
           begin
             raise exception 'injected audit fault';
           end $$""")
      discard database.execUpdate(
        """create trigger lock_atomic_audit_fault before insert on account.audit
           for each row execute function lock_atomic_audit_fault()""")
      let locked = call(baseUrl, HttpPost,
        "/c/" & slug & "/sessions/" & sessionId & "/lock", hostCookie,
        ifMatch = "\"3\"")
      discard database.execUpdate(
        "drop trigger if exists lock_atomic_audit_fault on account.audit")
      discard database.execUpdate(
        "drop function if exists lock_atomic_audit_fault()")
      check locked.status >= 500
      let after = artefacts(sessionId)
      check after.status == "draft"
      check after.events == 0
      check after.audits == 0

  purgeCommunity(database, slug)
  database.close()
