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

  test "a platform-scoped key cannot be overridden per community":
    let result = checkPatch(snapshot, %*{"security.max_body_bytes": 2048})
    check result.outcome == soPlatformScope

  test "an override above the platform value is rejected":
    let result = checkPatch(snapshot, %*{"rating.score_target": 50})
    check result.outcome == soOutOfCeiling

  test "an opt-in flag may be switched on by a community":
    # The platform value of these two keys is the default, not a ceiling: the
    # join path reads it with coalesce against the community value, and the
    # directory was always opt-in. Both must survive the patch route.
    check checkPatch(snapshot,
      %*{"community.join_requests_enabled": true}).outcome == soOk
    check checkPatch(snapshot,
      %*{"community.directory_enabled": true}).outcome == soOk

  test "a valid override is stored and audited":
    let result = applyPatch(db, snapshot, communityId, userId,
      %*{"rating.score_target": 15})
    check result.outcome == soOk
    let stored = currentSettings(db, communityId)
    check stored["rating.score_target"].getInt() == 15
    let auditRow = db.queryOne(
      """select before::text as before, after::text as after
         from account.audit
         where community_id = $1::uuid and action = 'config.override'
         order by occurred_at desc limit 1""",
      @[textParam(communityId)])
    check auditRow.isSome
    check parseJson(auditRow.get.get("after"))["rating.score_target"].getInt() == 15

  test "an unknown timezone is rejected":
    let rejected = applyPatch(db, snapshot, communityId, userId,
      %*{"community.default_timezone": "Mars/Olympus"})
    check rejected.outcome == soInvalidType
    check not currentSettings(db, communityId).hasKey("community.default_timezone")
    let accepted = applyPatch(db, snapshot, communityId, userId,
      %*{"community.default_timezone": "Asia/Makassar"})
    check accepted.outcome == soOk
    check currentSettings(db, communityId)["community.default_timezone"]
      .getStr() == "Asia/Makassar"

  test "an invalid second key leaves the first override untouched":
    discard applyPatch(db, snapshot, communityId, userId,
      %*{"rating.score_target": 15})
    let rejected = applyPatch(db, snapshot, communityId, userId,
      %*{"rating.score_target": 16, "security.max_body_bytes": 99999})
    check rejected.outcome == soPlatformScope
    check currentSettings(db, communityId)["rating.score_target"].getInt() == 15

  test "effective config reports the source of each value":
    discard applyPatch(db, snapshot, communityId, userId,
      %*{"rating.score_target": 14})
    let effective = effectiveConfig(snapshot, currentSettings(db, communityId))
    check effective["rating.score_target"]["source"].getStr() == "community"
    check effective["rating.score_target"]["value"].getInt() == 14
    # Booleans carry the policy: the screen locks a switch only when the server
    # says the key is not opt-in, so it never offers a save the route refuses.
    check effective["community.join_requests_enabled"]["widenable"].getBool()
    check effective["community.directory_enabled"]["widenable"].getBool()
    # Platform keys are not part of the community view: every member reads this.
    check not effective.hasKey("rank.board_limit")
    check not effective.hasKey("security.allowed_origins")
