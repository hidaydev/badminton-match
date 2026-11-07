import std/[json, options, strutils]
import cli
import db/db
import sha256
import account/domain/audit
import account/infrastructure/audit_store
import community/domain/community
import community/infrastructure/community_store
import platform/config/registry
import platform/config/store

const
  program = "ownerseed"
  usage = """Usage: ownerseed --sub <google-sub> [options]

  --sub <value>            Google subject of the first platform owner (required)
  --email <address>        Email of that account; stored hashed, never plaintext
  --display-name <name>    Display name (defaults to the email local part)
  --community-slug <slug>  Slug of the default community (default: default)
  --community-name <name>  Name of the default community (default: Default)
  --admin-email <address>  First admin of the default community (default: --email)
  --dry-run                Print what would change and exit

Requires MAJADU_PG_DSN. Run against an empty instance; a second, different
owner is refused. The owner gets no membership automatically (O-31)."""

type
  Options = object
    sub, email, displayName, communitySlug, communityName, adminEmail: string
    dryRun: bool

proc parseArgs(): Options =
  result.communitySlug = "default"
  result.communityName = "Default"
  for (flag, value) in flags(program, 1, ["--sub", "--email", "--display-name",
      "--community-slug", "--community-name", "--admin-email"]):
    case flag
    of "--sub":
      result.sub = value
    of "--email":
      result.email = value
    of "--display-name":
      result.displayName = value
    of "--community-slug":
      result.communitySlug = value
    of "--community-name":
      result.communityName = value
    of "--admin-email":
      result.adminEmail = value
    of "--dry-run":
      result.dryRun = true
    of "-h", "--help":
      echo usage
      quit(0)
    else:
      usageFail(program, "unknown argument: " & flag)
  if result.sub.strip().len == 0:
    usageFail(program, "--sub is required")
  if result.adminEmail.len == 0:
    result.adminEmail = result.email

proc existingOwner(conn: DbConn): (string, string) =
  let row = conn.queryOne(
    """select id, google_sub from platform.user
       where is_platform_owner order by created_at limit 1""")
  if row.isSome:
    (row.get.get("id"), row.get.get("google_sub"))
  else:
    ("", "")

proc ensureOwner(conn: DbConn, options: Options, created: var bool): string =
  ## Idempotent: a repeated run with the same subject changes nothing, so it
  ## must not append a second audit row.
  let (ownerId, ownerSub) = existingOwner(conn)
  if ownerId.len > 0:
    if ownerSub != options.sub:
      fail(program, "this instance already has a platform owner (" & ownerSub & ")")
    return ownerId
  if options.email.len == 0:
    usageFail(program, "--email is required when creating the owner")
  let taken = conn.queryOne(
    "select google_sub from platform.user where email_hash = $1",
    @[textParam(sha256Hex(options.email.strip().toLowerAscii()))])
  if taken.isSome:
    fail(program, "email already belongs to " & taken.get.get("google_sub"))
  let display =
    if options.displayName.len > 0: options.displayName
    else: options.email.split('@')[0]
  created = true
  conn.queryOne(
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
    fail(program, "default community is invalid: " & $check.problems[0])
  let created = communityStore.create(db, check.slug, options.communityName.strip(),
    options.adminEmail, check.timezone, "")
  if created.status != csOk:
    fail(program, "cannot create the default community")
  created.communityId

proc main() =
  let options = parseArgs()
  let db = openDb(dsnOrFail(program), 1)
  defer: db.close()

  let (existingId, _) = db.read(proc(conn: DbConn): (string, string) =
    existingOwner(conn))
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
  var ownerId = ""
  # The owner and its bootstrap row share one transaction: a failed audit rolls
  # the account back instead of leaving a platform owner with no evidence.
  db.tx(proc(conn: DbConn) =
    ownerId = ensureOwner(conn, options, created)
    if created:
      # `sub` is a stable external identifier and stays out of the audit table;
      # the row records the granted role instead, which is what the allowlist
      # accepts.
      recordAuditConn(conn, auditEvent("platform.owner.bootstrap",
        communityId = "", actorId = ownerId, actorRole = "platform_owner",
        targetKind = "user", targetId = ownerId, requestId = "cli").withEvidence(
          newJObject(), %*{"role": "platform_owner"})))

  let communityId = ensureDefaultCommunity(db, options)
  echo $(%*{
    "ownerId": ownerId,
    "communityId": communityId,
    "seeded": true,
  })

when isMainModule:
  main()
