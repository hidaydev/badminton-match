import std/[json, options, os, strutils, unittest]
import db/db
import sha256
import account/domain/lifecycle
import account/infrastructure/lifecycle_store
import account/infrastructure/session_store

var
  database: Db
  communityId, userId, actorId, playerId: string

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc cleanup() =
  for statement in [
    """delete from rating.deltas where community_id in
         (select id from platform.community where slug = 'lifeclub')""",
    """delete from rating.events where community_id in
         (select id from platform.community where slug = 'lifeclub')""",
    """delete from rating.player_state where community_id in
         (select id from platform.community where slug = 'lifeclub')""",
    """delete from player.claims where community_id in
         (select id from platform.community where slug = 'lifeclub')""",
    """delete from player.players where community_id in
         (select id from platform.community where slug = 'lifeclub')""",
    "delete from platform.community where slug in ('lifeclub', 'lifeclub-only')",
    """delete from account.audit where actor_id in
         (select id from platform.user where google_sub in ('lc-actor', 'lc-user'))""",
    "delete from platform.user where google_sub in ('lc-actor', 'lc-user')"]:
    discard database.execUpdate(statement)
  # A previous run may have rewritten the subject to its hash.
  discard database.execUpdate(
    "delete from platform.user where google_sub = $1",
    @[textParam(sha256Hex("lc-user"))])

proc seed() =
  actorId = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name, is_platform_owner)
       values ('lc-actor', $1, 'Actor', true) returning id""",
    @[textParam(sha256Hex("lc-actor@example.com"))]).get.get("id")
  userId = database.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name)
       values ('lc-user', $1, 'Leaving User') returning id""",
    @[textParam(sha256Hex("lc-user@example.com"))]).get.get("id")
  communityId = database.queryOne(
    """insert into platform.community (slug, name, timezone)
       values ('lifeclub', 'Life Club', 'Asia/Jakarta') returning id""").get.get("id")
  playerId = database.queryOne(
    """insert into player.players (community_id, canonical_name, gender, user_id)
       values ($1::uuid, 'Bound Player', 'M', $2::uuid) returning id""",
    @[textParam(communityId), textParam(userId)]).get.get("id")
  discard database.execUpdate(
    """insert into community.membership (community_id, user_id, role)
       values ($1::uuid, $2::uuid, 'admin')""",
    @[textParam(communityId), textParam(userId)])
  # A community the account joined but never played in: the anonymiser must
  # still find it through the membership row alone.
  let memberOnlyId = database.queryOne(
    """insert into platform.community (slug, name, timezone)
       values ('lifeclub-only', 'Life Club Only', 'Asia/Jakarta') returning id"""
    ).get.get("id")
  discard database.execUpdate(
    """insert into community.membership (community_id, user_id, role)
       values ($1::uuid, $2::uuid, 'member')""",
    @[textParam(memberOnlyId), textParam(userId)])
  discard database.execUpdate(
    """insert into player.claims
         (community_id, player_id, user_id, status, decided_by, decided_at, reason)
       values ($1::uuid, $2::uuid, $3::uuid, 'approved', $4::uuid, now(), 'seed')""",
    @[textParam(communityId), textParam(playerId), textParam(userId),
      textParam(actorId)])
  discard database.execUpdate(
    """insert into rating.player_state
         (community_id, player_id, rating, games_played, wins, losses)
       values ($1::uuid, $2::uuid, 900, 3, 2, 1)""",
    @[textParam(communityId), textParam(playerId)])
  let eventId = database.queryOne(
    """insert into rating.events (community_id, local_date, event_type)
       values ($1::uuid, current_date, 'session') returning id""",
    @[textParam(communityId)]).get.get("id")
  discard database.execUpdate(
    """insert into rating.deltas (community_id, event_id, side, player_id, delta)
       values ($1::uuid, $2::uuid, 'a', $3::uuid, 120)""",
    @[textParam(communityId), textParam(eventId), textParam(playerId)])
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

    check count("""select count(*)::int as n from rating.deltas
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
