import std/[json, options, os, unittest]
import db/db
import sha256
import ../../infrastructure/community_store

proc dsn(): string = getEnv("MAJADU_PG_DSN")

suite "community store":
  var db: Db
  var ownerId, memberId: string

  setup:
    if dsn().len == 0:
      raise newException(ValueError, "MAJADU_PG_DSN is required")
    db = openDb(dsn(), 1)
    for slug in ["store-open", "store-closed", "store-taken"]:
      discard db.execUpdate(
        """delete from community.invite where community_id in
             (select id from platform.community where slug = $1)""",
        @[textParam(slug)])
      discard db.execUpdate(
        "delete from platform.community where slug = $1", @[textParam(slug)])
    discard db.execUpdate("delete from platform.user where google_sub like 'store-%'")
    ownerId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name, is_platform_owner)
         values ('store-owner', 'store-owner-hash', 'Owner', true) returning id"""
      ).get.get("id")
    memberId = db.queryOne(
      """insert into platform.user (google_sub, email_hash, display_name)
         values ('store-member', 'store-member-hash', 'Member') returning id"""
      ).get.get("id")

  teardown:
    db.close()

  test "creating a community also creates the first admin invitation":
    let created = create(db, "store-open", "Store Open", "Admin@Example.com",
      "Asia/Jakarta", ownerId)
    check created.status == csOk
    let invite = db.queryOne(
      """select role, email_hash from community.invite
         where community_id = $1::uuid""", @[textParam(created.communityId)]).get
    check invite.get("role") == "admin"
    check invite.get("email_hash") == sha256Hex("admin@example.com")

  test "a taken slug is reported instead of raising":
    discard create(db, "store-taken", "First", "a@example.com", "Asia/Jakarta", ownerId)
    let second = create(db, "store-taken", "Second", "b@example.com",
      "Asia/Jakarta", ownerId)
    check second.status == csSlugTaken
    check db.queryOne(
      "select name from platform.community where slug = 'store-taken'"
      ).get.get("name") == "First"

  test "the directory hides opted-out communities from outsiders":
    let open = create(db, "store-open", "Store Open", "a@example.com",
      "Asia/Jakarta", ownerId)
    discard create(db, "store-closed", "Store Closed", "b@example.com",
      "Asia/Jakarta", ownerId)
    discard db.execUpdate(
      """insert into community.settings (community_id, values)
         values ($1::uuid, '{"community.directory_enabled": true}')""",
      @[textParam(open.communityId)])
    let outsider = directory(db, none(string), false, "community.directory_enabled")
    var slugs: seq[string] = @[]
    for entry in outsider:
      slugs.add(entry["slug"].getStr())
    check "store-open" in slugs
    check "store-closed" notin slugs

  test "members see their own community even when the directory is off":
    let closed = create(db, "store-closed", "Store Closed", "b@example.com",
      "Asia/Jakarta", ownerId)
    discard db.execUpdate(
      """insert into community.membership (community_id, user_id, role)
         values ($1::uuid, $2::uuid, 'member')""",
      @[textParam(closed.communityId), textParam(memberId)])
    let member = directory(db, some(memberId), false, "community.directory_enabled")
    var found = false
    for entry in member:
      if entry["slug"].getStr() == "store-closed":
        found = true
        check entry.len == 2
    check found

  test "the platform default turns the directory on for everyone":
    discard create(db, "store-closed", "Store Closed", "b@example.com",
      "Asia/Jakarta", ownerId)
    let outsider = directory(db, none(string), true, "community.directory_enabled")
    var found = false
    for entry in outsider:
      if entry["slug"].getStr() == "store-closed":
        found = true
    check found
