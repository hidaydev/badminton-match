import std/[json, options, os, strutils]
import db/db
import sha256
import account/domain/audit
import account/infrastructure/audit_store
import community/domain/community
import community/infrastructure/community_store
import platform/config/registry
import platform/config/store

const usage = """Usage: ownerseed --sub <google-sub> [options]

  --sub <value>            Google subject of the first platform owner (required)
  --email <address>        Email of that account; stored hashed, never plaintext
  --display-name <name>    Display name (defaults to the email local part)
  --community-slug <slug>  Slug of the default community (default: default)
  --community-name <name>  Name of the default community (default: Default)
  --admin-email <address>  First admin of the default community (default: --email)
  --dry-run                Print what would change and exit

Requires MAJADU_PG_DSN. Run against an empty instance; a second, different
owner is refused. The owner gets no membership automatically (O-31)."""

proc fail(message: string) {.noreturn.} =
  stderr.writeLine "ownerseed: " & message
  quit(2)

type
  Options = object
    sub, email, displayName, communitySlug, communityName, adminEmail: string
    dryRun: bool

proc parseArgs(): Options =
  result.communitySlug = "default"
  result.communityName = "Default"
  var index = 1
  while index <= paramCount():
    case paramStr(index)
    of "--sub":
      index.inc; result.sub = paramStr(index)
    of "--email":
      index.inc; result.email = paramStr(index)
    of "--display-name":
      index.inc; result.displayName = paramStr(index)
    of "--community-slug":
      index.inc; result.communitySlug = paramStr(index)
    of "--community-name":
      index.inc; result.communityName = paramStr(index)
    of "--admin-email":
      index.inc; result.adminEmail = paramStr(index)
    of "--dry-run":
      result.dryRun = true
    of "-h", "--help":
      echo usage
      quit(0)
    else:
      fail "unknown argument: " & paramStr(index)
    index.inc
  if result.sub.strip().len == 0:
    fail "--sub is required"
  if result.adminEmail.len == 0:
    result.adminEmail = result.email

proc existingOwner(db: Db): (string, string) =
  let row = db.queryOne(
    """select id, google_sub from platform.user
       where is_platform_owner order by created_at limit 1""")
  if row.isSome:
    (row.get.get("id"), row.get.get("google_sub"))
  else:
    ("", "")

proc ensureOwner(db: Db, options: Options, created: var bool): string =
  ## Idempotent: a repeated run with the same subject changes nothing, so it
  ## must not append a second audit row.
  let (ownerId, ownerSub) = existingOwner(db)
  if ownerId.len > 0:
    if ownerSub != options.sub:
      fail "this instance already has a platform owner (" & ownerSub & ")"
    return ownerId
  if options.email.len == 0:
    fail "--email is required when creating the owner"
  let taken = db.queryOne(
    "select google_sub from platform.user where email_hash = $1",
    @[textParam(sha256Hex(options.email.strip().toLowerAscii()))])
  if taken.isSome:
    fail "email already belongs to " & taken.get.get("google_sub")
  let display =
    if options.displayName.len > 0: options.displayName
    else: options.email.split('@')[0]
  created = true
  db.queryOne(
    """insert into platform.user (google_sub, email_hash, display_name,
                                  is_platform_owner)
       values ($1, $2, $3, true)
       returning id""",
    @[textParam(options.sub),
      textParam(sha256Hex(options.email.strip().toLowerAscii())),
      textParam(display)]).get.get("id")

proc ensureDefaultCommunity(db: Db, options: Options): string =
  let row = db.queryOne("select id from platform.community order by created_at limit 1")
  if row.isSome:
    return row.get.get("id")
  let timezone = loadSnapshot(db).stringValue(%*{}, keyCommunityDefaultTimezone)
  let check = checkCreate(options.communitySlug, options.communityName,
    options.adminEmail, timezone, none(string))
  if check.problems.len > 0:
    fail "default community is invalid: " & $check.problems[0]
  let created = communityStore.create(db, check.slug, options.communityName.strip(),
    options.adminEmail, check.timezone, "")
  if created.status != csOk:
    fail "cannot create the default community"
  created.communityId

proc main() =
  let options = parseArgs()
  let dsn = getEnv("MAJADU_PG_DSN")
  if dsn.len == 0:
    fail "MAJADU_PG_DSN is required"
  let db = openDb(dsn, 1)
  defer: db.close()

  let (existingId, _) = existingOwner(db)
  if options.dryRun:
    let community = db.queryOne(
      "select id from platform.community order by created_at limit 1")
    echo $(%*{
      "dryRun": true,
      "ownerExists": existingId.len > 0,
      "communityExists": community.isSome,
    })
    return

  var created = false
  let ownerId = ensureOwner(db, options, created)
  if created:
    recordAudit(db, auditEvent("platform.owner.bootstrap", communityId = "",
      actorId = ownerId, actorRole = "platform_owner", targetKind = "user",
      targetId = ownerId, requestId = "cli").withEvidence(newJObject(),
        %*{"sub": options.sub}))

  let communityId = ensureDefaultCommunity(db, options)
  echo $(%*{
    "ownerId": ownerId,
    "communityId": communityId,
    "seeded": true,
  })

when isMainModule:
  main()
