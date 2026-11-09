import std/[options, os, strutils, tables, unittest]
import db/db
import platform/janitor
import platform/audit_retention
import tests/fixtures
import "../../../../shared/platform-lib/tests/clock_fixture"

proc dsn(): string = getEnv("MAJADU_PG_DSN")

# Every fixture timestamp is an absolute instant. Nothing in this file writes
# `now() - interval`; the pinned clock below is the only source of "now", so the
# window a case asserts is the window the janitor sees.
const
  pinned = "2026-11-08T00:00:00Z"
  epoch = "2026-01-01T00:00:00Z"
  fresh = "2026-11-08T00:00:00Z"
  retentionDays = 30

proc keysOf(db: Db, userId: string): seq[string] =
  for row in db.query(
    "select key from platform.idempotency_keys where user_id = $1::uuid order by key",
    @[textParam(userId)]):
    result.add(row.get("key"))

suite "janitor":
  var db: Db
  var communityId, userId, sessionId: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    purgeCommunity(db, "janitor-test")
    discard db.execUpdate("delete from platform.user where google_sub = 'janitor-test'")
    discard db.execUpdate("delete from platform.outbox where topic = 'janitor-test'")
    discard db.execUpdate("delete from auth.oauth_flows where return_to = '/janitor-test'")
    userId = newUser(db, "janitor-test", "janitor-hash", "Janitor")
    communityId = newCommunity(db, "janitor-test", "Janitor Test")
    sessionId = newSession(db, communityId, "Janitor", "2026-11-03",
      startTime = "19:00")
    discard db.execUpdate(
      """insert into auth.oauth_flows
           (state_hash, nonce_hash, code_verifier_enc, key_id, return_to,
            created_at, expires_at)
         values (decode(repeat('11', 32), 'hex'), decode(repeat('22', 32), 'hex'),
                 'x', '1', '/janitor-test', $1::timestamptz, $1::timestamptz)""",
      @[textParam(epoch)])
    discard db.execUpdate(
      """insert into platform.idempotency_keys (user_id, key, body_hash, created_at, expires_at)
         values ($1::uuid, 'expired', 'h', $2::timestamptz, $2::timestamptz)""",
      @[textParam(userId), textParam(epoch)])
    discard db.execUpdate(
      """insert into platform.idempotency_keys (user_id, key, body_hash, created_at, expires_at)
         values ($1::uuid, 'fresh', 'h', $2::timestamptz, $2::timestamptz)""",
      @[textParam(userId), textParam(fresh)])
    discard db.execUpdate(
      """insert into platform.outbox (topic, payload, created_at, processed_at)
         values ('janitor-test', '{}', $1::timestamptz, $1::timestamptz)""",
      @[textParam(epoch)])
    discard db.execUpdate(
      """insert into platform.outbox (topic, payload, created_at)
         values ('janitor-test', '{}', $1::timestamptz)""",
      @[textParam(epoch)])
    discard db.execUpdate(
      """insert into session.links
           (id, community_id, session_id, code_hash, code_enc, key_id, created_at, revoked_at)
         values (gen_random_uuid(), $1::uuid, $2::uuid, decode(repeat('33', 32), 'hex'),
                 'code', 'k', $3::timestamptz, $3::timestamptz)""",
      @[textParam(communityId), textParam(sessionId), textParam(epoch)])
    discard db.execUpdate(
      """insert into session.links
           (id, community_id, session_id, code_hash, code_enc, key_id, created_at)
         values (gen_random_uuid(), $1::uuid, $2::uuid, decode(repeat('44', 32), 'hex'),
                 'code', 'k', $3::timestamptz)""",
      @[textParam(communityId), textParam(sessionId), textParam(fresh)])
    discard db.execUpdate(
      """insert into platform.ws_ticket
           (token_hash, channel_kind, channel_id, user_id, created_at, expires_at)
         values (decode(repeat('55', 32), 'hex'), 'session', $1::uuid, $2::uuid,
                 $3::timestamptz, $3::timestamptz)""",
      @[textParam(sessionId), textParam(userId), textParam(epoch)])
    discard db.execUpdate(
      """insert into platform.ws_ticket
           (token_hash, channel_kind, channel_id, user_id, created_at, expires_at)
         values (decode(repeat('66', 32), 'hex'), 'session', $1::uuid, $2::uuid,
                 $3::timestamptz, $3::timestamptz)""",
      @[textParam(sessionId), textParam(userId), textParam(fresh)])
    discard db.execUpdate(
      """insert into account.audit
           (occurred_at, actor_role, action, target_kind, target_id, result, request_id)
         values ($1::timestamptz, 'admin', 'janitor.test', 'session', 'x',
                 'allow', '-'),
                ($2::timestamptz, 'admin', 'janitor.recent', 'session', 'y', 'allow', '-')""",
      @[textParam("2025-01-01T00:00:00Z"), textParam(fresh)])

  teardown:
    db.close()

  test "expired temporary rows are deleted and live rows are kept":
    var byTable = initTable[string, int]()
    withPinnedClock(pinned):
      for outcome in purge(db, retentionDays):
        byTable[outcome.table] = outcome.deleted
    check byTable["auth.oauth_flows"] >= 1
    check byTable["platform.idempotency_keys"] >= 1
    check byTable["platform.outbox"] >= 1
    check byTable["session.links"] >= 1
    check byTable["platform.ws_ticket"] >= 1
    # Exact rows, not counts: the expired row is gone and the fresh one is the
    # only survivor of its table for this fixture.
    let flows = db.queryOne(
      "select count(*) as total from auth.oauth_flows where return_to = '/janitor-test'"
      ).get.get("total")
    check flows == "0"
    check keysOf(db, userId) == @["fresh"]
    let outbox = db.query(
      """select processed_at is null as pending from platform.outbox
         where topic = 'janitor-test'""")
    check outbox.len == 1
    check outbox[0].get("pending") == "t"
    let links = db.query(
      """select encode(code_hash, 'hex') as code from session.links
         where community_id = $1::uuid""",
      @[textParam(communityId)])
    check links.len == 1
    check links[0].get("code") == repeat("44", 32)
    let tickets = db.query(
      """select encode(token_hash, 'hex') as token from platform.ws_ticket
         where channel_id = $1::uuid order by token""",
      @[textParam(sessionId)])
    check tickets.len == 1
    check tickets[0].get("token") == repeat("66", 32)

  test "a zero-day window cuts at the pinned instant and keeps the fresh row":
    # The cutoff is the pinned instant itself, not the later database clock, so
    # the row written at that instant survives and the epoch row does not.
    withPinnedClock(pinned):
      discard purge(db, 0)
    check keysOf(db, userId) == @["fresh"]

  test "the application janitor never touches audit":
    let before = db.queryOne(
      "select count(*) as total from account.audit").get.get("total")
    withPinnedClock(pinned):
      discard purge(db, 1)
    let after = db.queryOne(
      "select count(*) as total from account.audit").get.get("total")
    check after == before
    let survivor = db.queryOne(
      """select count(*) as total from account.audit
         where action = 'janitor.test'""").get.get("total")
    check survivor != "0"

  test "the application role cannot delete audit rows":
    let allowed = db.queryOne(
      """select has_table_privilege('bm2_app', 'account.audit', 'DELETE') as allowed"""
      ).get.get("allowed")
    check allowed == "f"

  test "the owner-run cleaner removes only rows beyond the window":
    discard purgeAudit(db, 365)
    let old = db.queryOne(
      """select count(*) as total from account.audit
         where action = 'janitor.test'""").get.get("total")
    check old == "0"
    let recent = db.queryOne(
      """select count(*) as total from account.audit
         where action = 'janitor.recent'""").get.get("total")
    check recent != "0"

  test "the retention predicate uses the occurred_at index":
    # With sequential scans disabled the planner can only pick an index, so
    # this fails if 0035 is missing instead of passing on a tiny table.
    var plan = ""
    db.tx(proc(conn: DbConn) =
      discard conn.execUpdate("set local enable_seqscan = off")
      for row in conn.query(
        """explain (costs off) select count(*) from account.audit
           where occurred_at < now() - interval '365 days'"""):
        plan.add(row.get("QUERY PLAN") & "\n"))
    check plan.contains("audit_occurred_at_idx")

  test "the purge drains more rows than one batch":
    for _ in 0 ..< 25:
      discard db.execUpdate(
        """insert into account.audit
             (actor_role, action, target_kind, target_id, result, request_id,
              occurred_at)
           values ('owner', 'retention.batch', 'test', 'x', 'allow', '-',
                   now() - interval '400 days')""")
    let deleted = purgeAudit(db, 365, batchSize = 10)
    check deleted >= 25
    check db.queryOne(
      """select count(*) as total from account.audit
         where action = 'retention.batch'""").get.get("total") == "0"
