import std/[json, options, strutils, sysrand]
import db/db
import sha256
import ../domain/community

type
  CreateStatus* = enum
    csOk = "ok"
    csSlugTaken = "slug_taken"

  CreateResult* = object
    status*: CreateStatus
    communityId*: string

proc randomToken(): string =
  var bytes = newSeq[byte](32)
  if not urandom(bytes):
    raise newException(IOError, "no entropy available")
  for byte in bytes:
    result.add(toHex(byte, 2).toLowerAscii())

proc create*(db: Db, slug, name, adminEmail, timezone, actorId: string): CreateResult =
  ## Creates the community and the first admin invitation in one transaction:
  ## a community without an admin has no way to be managed (COM-01).
  var taken = false
  var communityId = ""
  discard db.tx(proc(conn: DbConn): int =
    let row = conn.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ($1, $2, $3)
         on conflict (slug) do nothing
         returning id""",
      @[textParam(slug), textParam(name), textParam(timezone)])
    if row.isNone:
      taken = true
    else:
      communityId = row.get.get("id")
      # The first-admin invitation is bound to the address, not to a bearer
      # token: the account becomes admin the first time that email logs in.
      discard conn.execUpdate(
        """insert into community.invite
             (community_id, token_hash, email_hash, role, created_by)
           values ($1::uuid, decode($2,'hex'), $3, 'admin', $4::uuid)""",
        @[
          textParam(communityId),
          textParam(sha256Hex(randomToken())),
          textParam(sha256Hex(adminEmail.strip().toLowerAscii())),
          textParam(actorId),
        ])
    1)
  if taken:
    CreateResult(status: csSlugTaken)
  else:
    CreateResult(status: csOk, communityId: communityId)

proc directory*(db: Db, userId: Option[string], platformDefault: bool,
                key: string): JsonNode =
  ## Lists the communities this caller may see: opted-in ones plus their own.
  ## Entries never carry counts, owners or settings (COM-08).
  result = newJArray()
  let memberParam = if userId.isSome: textParam(userId.get) else: nullParam()
  for row in db.query(
    """select c.slug, c.name,
              coalesce((s.values ->> $1)::boolean, $2) as enabled,
              (m.user_id is not null) as member
       from platform.community c
       left join community.settings s on s.community_id = c.id
       left join community.membership m
         on m.community_id = c.id and m.user_id = $3::uuid
       order by c.slug""",
    @[textParam(key), boolParam(platformDefault), memberParam]):
    let enabled = row.get("enabled") == "t"
    let member = row.get("member") == "t"
    if directoryVisible(enabled, member):
      result.add(directoryEntry(row.get("slug"), row.get("name")))
