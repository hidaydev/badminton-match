import std/[json, options, os, strutils, unittest]
import db/db
import sha256
import account/domain/lifecycle
import account/infrastructure/lifecycle_store
import account/infrastructure/session_store
import rating/infrastructure/ledger
import tests/fixtures

var
  database: Db
  communityId, userId, actorId, playerId: string

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc cleanup() =
  for slug in ["lifeclub", "lifeclub-only"]:
    purgeCommunity(database, slug)
  discard database.execUpdate(
    """delete from account.audit where actor_id in
         (select id from platform.user where google_sub in ('lc-actor', 'lc-user'))""")
  discard database.execUpdate(
    "delete from platform.user where google_sub in ('lc-actor', 'lc-user')")
  # A previous run may have rewritten the subject to its hash.
  discard database.execUpdate(
    "delete from platform.user where google_sub = $1",
    @[textParam(sha256Hex("lc-user"))])

proc seed() =
  actorId = newUser(database, "lc-actor", "lc-actor@example.com", "Actor",
    owner = true)
  userId = newUser(database, "lc-user", "lc-user@example.com", "Leaving User")
  communityId = newCommunity(database, "lifeclub", "Life Club")
  playerId = newPlayer(database, communityId, "Bound Player", userId = userId)
  newMember(database, communityId, userId, "admin")
  # A community the account joined but never played in: the anonymiser must
  # still find it through the membership row alone.
  let memberOnlyId = newCommunity(database, "lifeclub-only", "Life Club Only")
  newMember(database, memberOnlyId, userId, "member")
  discard database.execUpdate(
    """insert into player.claims
         (community_id, player_id, user_id, status, decided_by, decided_at, reason)
       values ($1::uuid, $2::uuid, $3::uuid, 'approved', $4::uuid, now(), 'seed')""",
    @[textParam(communityId), textParam(playerId), textParam(userId),
      textParam(actorId)])
  database.tx(proc(conn: DbConn) =
    addState(conn, communityId, @[playerId], won = true)
    addState(conn, communityId, @[playerId], won = true)
    addState(conn, communityId, @[playerId], won = false))
  discard database.queryOne(
    """insert into rating.events (community_id, local_date, event_type)
       values ($1::uuid, current_date, 'session') returning id""",
    @[textParam(communityId)])
  discard createSession(database, userId, 30)

proc count(sql: string): int =
  parseInt(database.queryOne(sql).get.get("n"))

database = openDb(dsn(), 1)
cleanup()
seed()

suite "account lifecycle":
  test "an anonymised account keeps the history but loses the person":
    check anonymize(database, userId, actorId, "account_anonymized") == lrOk
    let row = database.queryOne(
      """select google_sub, email_hash, display_name from platform.user
         where id = $1::uuid""", @[textParam(userId)]).get
    check row.get("google_sub") == sha256Hex("lc-user")
    check row.get("display_name") == ""
    check isAnonymized(row.get("email_hash"), userId)

    let claim = database.queryOne(
      """select status, reason from player.claims where player_id = $1::uuid""",
      @[textParam(playerId)]).get
    check claim.get("status") == "released"
    check claim.get("reason") == "account_anonymized"

    let player = database.queryOne(
      """select user_id from player.players where id = $1::uuid""",
      @[textParam(playerId)]).get
    check player["user_id"].isNone

    # Membership is account data: both communities go, including the one that
    # only exists as a membership row.
    check count("""select count(*)::int as n from community.membership
                   where user_id = '""" & userId & """'""") == 0

    check count("""select count(*)::int as n from rating.events
                   where community_id = '""" & communityId & """'""") == 1
    check count("""select count(*)::int as n from rating.player_state
                   where community_id = '""" & communityId & """'""") == 1
    check count("""select count(*)::int as n from account.sessions
                   where user_id = '""" & userId & """'""") == 0
    check count("""select count(*)::int as n from account.audit
                   where action = 'account.anonymize' and target_id = '""" &
                 userId & """'""") == 1

  test "running it twice is reported, not repeated":
    check anonymize(database, userId, actorId, "account_anonymized") == lrAlready
    check count("""select count(*)::int as n from account.audit
                   where action = 'account.anonymize' and target_id = '""" &
                 userId & """'""") == 1

  test "an unknown account is a clean miss":
    check anonymize(database, "00000000-0000-0000-0000-000000000000", actorId,
      "account_anonymized") == lrNotFound
