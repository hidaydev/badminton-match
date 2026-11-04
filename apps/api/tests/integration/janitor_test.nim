import std/[options, os, tables, unittest]
import db/db
import platform/janitor
import platform/audit_retention

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "janitor":
  var db: Db
  var communityId, userId, sessionId: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    discard db.execUpdate(
      "delete from session.links where community_id in (select id from platform.community where slug = 'janitor-test')")
    discard db.execUpdate(
      "delete from session.sessions where community_id in (select id from platform.community where slug = 'janitor-test')")
    discard db.execUpdate("delete from platform.community where slug = 'janitor-test'")
    discard db.execUpdate("delete from platform.user where google_sub = 'janitor-test'")
    discard db.execUpdate("delete from platform.outbox where topic = 'janitor-test'")
    discard db.execUpdate("delete from auth.oauth_flows where return_to = '/janitor-test'")
    userId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('janitor-test', 'janitor-hash', 'Janitor') returning id""").get.get("id")
    communityId = db.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('janitor-test', 'Janitor Test', 'Asia/Jakarta') returning id""").get.get("id")
    sessionId = db.queryOne(
      """insert into session.sessions
           (community_id, title, session_date, start_time, slot_minutes, status, source)
         values ($1::uuid, 'Janitor', '2026-11-03', '19:00', 30, 'draft', 'manual')
         returning id""", @[textParam(communityId)]).get.get("id")
    discard db.execUpdate(
      """insert into auth.oauth_flows
           (state_hash, nonce_hash, code_verifier_enc, return_to, created_at, expires_at)
         values (decode(repeat('11', 32), 'hex'), decode(repeat('22', 32), 'hex'),
                 'x', '/janitor-test', now() - interval '40 days',
                 now() - interval '40 days')""")
    discard db.execUpdate(
      """insert into platform.idempotency_keys (user_id, key, body_hash, created_at, expires_at)
         values ($1::uuid, 'expired', 'h', now() - interval '40 days',
                 now() - interval '40 days')""", @[textParam(userId)])
    discard db.execUpdate(
      """insert into platform.idempotency_keys (user_id, key, body_hash, created_at, expires_at)
         values ($1::uuid, 'fresh', 'h', now(), now() + interval '1 day')""",
      @[textParam(userId)])
    discard db.execUpdate(
      """insert into platform.outbox (topic, payload, created_at, processed_at)
         values ('janitor-test', '{}', now() - interval '40 days',
                 now() - interval '40 days')""")
    discard db.execUpdate(
      """insert into platform.outbox (topic, payload, created_at)
         values ('janitor-test', '{}', now() - interval '40 days')""")
    discard db.execUpdate(
      """insert into session.links
           (id, community_id, session_id, code_hash, code_enc, key_id, created_at, revoked_at)
         values (gen_random_uuid(), $1::uuid, $2::uuid, decode(repeat('33', 32), 'hex'),
                 'code', 'k', now() - interval '40 days', now() - interval '40 days')""",
      @[textParam(communityId), textParam(sessionId)])
    discard db.execUpdate(
      """insert into session.links
           (id, community_id, session_id, code_hash, code_enc, key_id, created_at)
         values (gen_random_uuid(), $1::uuid, $2::uuid, decode(repeat('44', 32), 'hex'),
                 'code', 'k', now())""",
      @[textParam(communityId), textParam(sessionId)])
    discard db.execUpdate(
      """insert into platform.ws_ticket
           (token_hash, channel_kind, channel_id, user_id, created_at, expires_at)
         values (decode(repeat('55', 32), 'hex'), 'session', $1::uuid, $2::uuid,
                 now() - interval '40 days', now() - interval '40 days')""",
      @[textParam(sessionId), textParam(userId)])
    discard db.execUpdate(
      """insert into platform.ws_ticket
           (token_hash, channel_kind, channel_id, user_id, created_at, expires_at)
         values (decode(repeat('66', 32), 'hex'), 'session', $1::uuid, $2::uuid,
                 now(), now() + interval '1 minute')""",
      @[textParam(sessionId), textParam(userId)])
    discard db.execUpdate(
      """insert into account.audit
           (occurred_at, actor_role, action, target_kind, target_id, result, request_id)
         values (now() - interval '400 days', 'admin', 'janitor.test', 'session', 'x',
                 'allow', '-'),
                (now(), 'admin', 'janitor.recent', 'session', 'y', 'allow', '-')""")

  teardown:
    db.close()

  test "expired temporary rows are deleted and live rows are kept":
    let outcomes = purge(db, 30)
    var byTable = initTable[string, int]()
    for outcome in outcomes:
      byTable[outcome.table] = outcome.deleted
    check byTable["auth.oauth_flows"] >= 1
    check byTable["platform.idempotency_keys"] >= 1
    check byTable["platform.outbox"] >= 1
    check byTable["session.links"] >= 1
    check byTable["platform.ws_ticket"] >= 1
    let freshKeys = db.queryOne(
      "select count(*) as total from platform.idempotency_keys where key = 'fresh'"
      ).get.get("total")
    check freshKeys == "1"
    let pending = db.queryOne(
      "select count(*) as total from platform.outbox where processed_at is null"
      ).get.get("total")
    check pending == "1"
    let liveLinks = db.queryOne(
      """select count(*) as total from session.links
         where community_id = $1::uuid and revoked_at is null""",
      @[textParam(communityId)]).get.get("total")
    check liveLinks == "1"

  test "the application janitor never touches audit":
    let before = db.queryOne(
      "select count(*) as total from account.audit").get.get("total")
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
