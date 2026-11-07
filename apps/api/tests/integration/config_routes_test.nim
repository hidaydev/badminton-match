import std/[json, options, os, unittest]
import db/db
import platform/config/store
import tests/fixtures
import ../../src/config_routes

proc dsn(): string = getEnv("MAJADU_PG_DSN")

proc readWithLoweredPlatform(db: Db, communityId: string, key: ConfigKey,
                             lowered: int): tuple[read, screen: int] =
  ## Lowers the platform value, reads the community override back, and restores
  ## the platform value even when the read raises: the row belongs to the shared
  ## suite database, not to this test.
  let stored = db.queryOne(
    "select value::text as value from platform.config where key = $1",
    @[textParam($key)])
  if stored.isNone:
    raise newException(ValueError, "missing platform value for " & $key)
  try:
    discard db.execUpdate(
      "update platform.config set value = $1 where key = $2",
      @[textParam($lowered), textParam($key)])
    let snapshot = loadSnapshot(db)
    let settings = currentSettings(db, communityId)
    result.read = snapshot.intValue(settings, key)
    result.screen = effectiveConfig(snapshot, settings)[$key]["value"].getInt()
  finally:
    discard db.execUpdate(
      "update platform.config set value = $1 where key = $2",
      @[textParam(stored.get.get("value")), textParam($key)])

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
      db.tx(proc(conn: DbConn) =
        conn.execScript(seed))
    snapshot = loadSnapshot(db)
    purgeCommunity(db, "cfg-test")
    discard db.execUpdate("delete from platform.user where google_sub = 'cfg-test'")
    userId = newUser(db, "cfg-test", "cfg-hash", "Admin")
    communityId = newCommunity(db, "cfg-test", "Config Test")

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

  test "a stored override reads as the platform value once the platform value drops":
    # The DoD for X-4. The write path accepted 20 while the platform value was
    # 30; the operator then lowers the platform value to 10. The stored row is
    # legal history, so the read clamps instead of raising, and the settings
    # screen shows the same number the server uses.
    discard applyPatch(db, snapshot, communityId, userId,
      %*{"rating.score_target": 20})
    let (read, screen) = readWithLoweredPlatform(db, communityId,
      keyRatingScoreTarget, 10)
    check read == 10
    check screen == 10
    # The clamp is a read, not a migration: the row still holds what was
    # written, so raising the platform value again restores the override.
    check currentSettings(db, communityId)["rating.score_target"].getInt() == 20
    check loadSnapshot(db).intValue(currentSettings(db, communityId),
      keyRatingScoreTarget) == 20
