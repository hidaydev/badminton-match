import std/[json, options, os, strutils, tables, unittest]
import db/db
import ../../store
import ../../registry

proc dsn(): string =
  getEnv("MAJADU_PG_DSN")

type
  SnapshotJob = object
    dsn: string
    cache: ConfigCache
    timezone: string
    failed: bool

proc readSnapshot(job: ptr SnapshotJob) {.thread.} =
  {.cast(gcsafe).}:
    try:
      let db = openDb(job.dsn, 1)
      try:
        job.timezone = job.cache.snapshot(db).stringValue(%*{},
          keyCommunityDefaultTimezone)
      finally:
        db.close()
    except CatchableError:
      job.failed = true

proc bumpTimezone(db: Db, value: string) =
  db.tx(proc(conn: DbConn) =
    discard conn.execUpdate(
      "update platform.config set value = $1 where key = $2",
      @[textParam("\"" & value & "\""), textParam($keyCommunityDefaultTimezone)])
    discard conn.execUpdate(
      "update platform.config_version set version = version + 1"))

proc seedPresent(db: Db): bool =
  db.queryOne("select count(*) as total from platform.config").get.get("total") != "0"

proc restoreConfig(db: Db) =
  ## The seed ends with `on conflict (key) do nothing`, so a modified row would
  ## survive a plain re-apply. Clear L1 first and apply the same file dbtools
  ## uses, so a raised test cannot leave a doctored value for every later suite.
  db.tx(proc(conn: DbConn) =
    discard conn.execUpdate("delete from platform.config")
    conn.execScript(readFile("db/seeds/platform_config.sql")))

suite "platform config":
  var db: Db
  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    if not seedPresent(db):
      # Self-seeding keeps the suite runnable on a database that was only
      # migrated; the seed file is the same one dbtools applies in production.
      let seed = readFile("db/seeds/platform_config.sql")
      db.tx(proc(conn: DbConn) =
        conn.execScript(seed))

  teardown:
    restoreConfig(db)
    db.close()

  test "every registry key is present and valid":
    let snapshot = loadSnapshot(db)
    for entry in allKeys:
      check snapshot.values.hasKey($entry.key)

  test "the business defaults load":
    let snapshot = loadSnapshot(db)
    check snapshot.intValue(%*{}, keyShareLinkTtlDays) == 30
    check snapshot.intValue(%*{}, keyApiPageSizeMax) == 500
    check snapshot.intValue(%*{}, keySessionSlotMinutesDefault) == 30

  test "missing key refuses to load":
    discard db.execUpdate("delete from platform.config where key = $1",
      @[textParam($keyWsTicketTtlSeconds)])
    var caught = false
    try:
      discard loadSnapshot(db)
    except ConfigError as error:
      caught = true
      check error.msg.contains("missing key")
    check caught

  test "a stored scope that disagrees with the registry refuses to load":
    discard db.execUpdate(
      "update platform.config set scope = 'community' where key = $1",
      @[textParam($keyWsTicketTtlSeconds)])
    var caught = false
    try:
      discard loadSnapshot(db)
    except ConfigError as error:
      caught = true
      check error.msg.contains("scope mismatch")
    discard db.execUpdate(
      "update platform.config set scope = 'platform' where key = $1",
      @[textParam($keyWsTicketTtlSeconds)])
    check caught

  test "value outside bounds refuses to load":
    discard db.execUpdate("update platform.config set value = '0' where key = $1",
      @[textParam($keyWsTicketTtlSeconds)])
    var caught = false
    try:
      discard loadSnapshot(db)
    except ConfigError:
      caught = true
    check caught

  test "writing the registry bumps the version by itself":
    # The cache watches `config_version`, and the trigger is what makes an
    # operator's `update platform.config` visible without a manual bump.
    let before = parseInt(db.queryOne(
      "select version from platform.config_version").get.get("version"))
    discard db.execUpdate(
      "update platform.config set value = value where key = $1",
      @[textParam($keyCommunityDefaultTimezone)])
    let after = parseInt(db.queryOne(
      "select version from platform.config_version").get.get("version"))
    check after > before

  test "a bump of config_version reloads without restart":
    let cache = newConfigCache(db)
    let before = cache.snapshot(db).stringValue(%*{}, keyCommunityDefaultTimezone)
    check before == "Asia/Jakarta"
    db.tx(proc(conn: DbConn) =
      discard conn.execUpdate(
        "update platform.config set value = '\"Asia/Makassar\"' where key = $1",
        @[textParam($keyCommunityDefaultTimezone)])
      discard conn.execUpdate("update platform.config_version set version = version + 1"))
    let after = cache.snapshot(db).stringValue(%*{}, keyCommunityDefaultTimezone)
    check after == "Asia/Makassar"
    db.tx(proc(conn: DbConn) =
      discard conn.execUpdate(
        "update platform.config set value = '\"Asia/Jakarta\"' where key = $1",
        @[textParam($keyCommunityDefaultTimezone)])
      discard conn.execUpdate("update platform.config_version set version = version + 1"))
    check cache.snapshot(db).stringValue(%*{}, keyCommunityDefaultTimezone) == "Asia/Jakarta"

  test "concurrent readers reload the bumped version and never downgrade":
    let cache = newConfigCache(db)
    bumpTimezone(db, "Asia/Jayapura")
    var first = SnapshotJob(dsn: dsn(), cache: cache)
    var second = SnapshotJob(dsn: dsn(), cache: cache)
    var firstThread: Thread[ptr SnapshotJob]
    var secondThread: Thread[ptr SnapshotJob]
    createThread(firstThread, readSnapshot, addr first)
    createThread(secondThread, readSnapshot, addr second)
    joinThread(firstThread)
    joinThread(secondThread)
    check not first.failed
    check not second.failed
    check first.timezone == "Asia/Jayapura"
    check second.timezone == "Asia/Jayapura"
    # An older snapshot may not win just because it finished its load last.
    check cache.snapshot(db).stringValue(%*{}, keyCommunityDefaultTimezone) ==
      "Asia/Jayapura"
    bumpTimezone(db, "Asia/Jakarta")

  test "L2 override below the L1 value wins":
    let snapshot = loadSnapshot(db)
    let settings = %*{"api.page_size_default": 25}
    check snapshot.intValue(settings, keyApiPageSizeDefault) == 25

  test "an override above the L1 value reads as the L1 value":
    # An override the write path accepted stays readable after an operator
    # lowers the platform value: the read clamps, and only the write path
    # reports the rejection. Raising here would turn that stored row into an
    # error for every member.
    let snapshot = loadSnapshot(db)
    check snapshot.intValue(%*{"api.page_size_default": 250},
      keyApiPageSizeDefault) == 100

  test "the registry bound is still a hard validity check":
    # The registry bound is validity, not the ceiling: a stored value outside
    # the frozen bounds still refuses the read.
    let snapshot = loadSnapshot(db)
    expect ConfigError:
      discard snapshot.intValue(%*{"api.page_size_default": 5000},
        keyApiPageSizeDefault)

  test "a decimal override is clamped the same way":
    let snapshot = loadSnapshot(db)
    check snapshot.decimalValue(%*{}, keyRatingSessionBase) == 250.0
    check snapshot.decimalValue(%*{"rating.session_base": 251.0},
      keyRatingSessionBase) == 250.0
