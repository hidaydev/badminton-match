import std/[json, options, os, unittest]
import db/db
import platform/config/store
import ../../src/config_routes

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "community config overrides":
  var db: Db
  var snapshot: Snapshot
  var communityId, userId: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    if db.queryOne("select count(*) as total from platform.config").get.get("total") == "0":
      let seed = readFile("db/seeds/platform_config.sql")
      discard db.tx(proc(conn: DbConn): int =
        conn.execScript(seed)
        1)
    snapshot = loadSnapshot(db)
    discard db.execUpdate(
      "delete from community.settings where community_id in (select id from platform.community where slug = 'cfg-test')")
    discard db.execUpdate(
      "delete from platform.community where slug = 'cfg-test'")
    discard db.execUpdate("delete from platform.user where google_sub = 'cfg-test'")
    userId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('cfg-test', 'cfg-hash', 'Admin') returning id""").get.get("id")
    communityId = db.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ('cfg-test', 'Config Test', 'Asia/Jakarta') returning id""").get.get("id")

  teardown:
    db.close()

  test "an unknown key is rejected":
    check checkPatch(snapshot, %*{"nope.value": 1}).outcome == soUnknownKey

  test "an override above the platform value is rejected":
    let result = checkPatch(snapshot, %*{"api.page_size_default": 100000})
    check result.outcome == soOutOfCeiling

  test "a valid override is stored and audited":
    let result = applyPatch(db, snapshot, communityId, userId,
      %*{"api.page_size_default": 25})
    check result.outcome == soOk
    let stored = currentSettings(db, communityId)
    check stored["api.page_size_default"].getInt() == 25
    let auditRow = db.queryOne(
      """select before::text as before, after::text as after
         from account.audit
         where community_id = $1::uuid and action = 'config.override'
         order by occurred_at desc limit 1""",
      @[textParam(communityId)])
    check auditRow.isSome
    check parseJson(auditRow.get.get("after"))["api.page_size_default"].getInt() == 25

  test "an invalid second key leaves the first override untouched":
    discard applyPatch(db, snapshot, communityId, userId,
      %*{"api.page_size_default": 30})
    let rejected = applyPatch(db, snapshot, communityId, userId,
      %*{"api.page_size_default": 40, "security.max_body_bytes": 99999999})
    check rejected.outcome == soOutOfCeiling
    check currentSettings(db, communityId)["api.page_size_default"].getInt() == 30

  test "effective config reports the source of each value":
    discard applyPatch(db, snapshot, communityId, userId,
      %*{"api.page_size_default": 15})
    let effective = effectiveConfig(snapshot, currentSettings(db, communityId))
    check effective["api.page_size_default"]["source"].getStr() == "community"
    check effective["api.page_size_default"]["value"].getInt() == 15
    check effective["rank.board_limit"]["source"].getStr() == "platform"
