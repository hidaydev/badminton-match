import std/[json, options, strutils]
import db/db
import sha256
import ../domain/community
import token

type
  CreateStatus* = enum
    csOk = "ok"
    csSlugTaken = "slug_taken"

  CreateResult* = object
    status*: CreateStatus
    communityId*: string

proc create*(db: Db, slug, name, adminEmail, timezone, actorId: string): CreateResult =
  ## Creates the community and the first admin invitation in one transaction:
  ## a community without an admin has no way to be managed (COM-01).
  var taken = false
  var communityId = ""
  db.tx(proc(conn: DbConn) =
    let row = conn.queryOne(
      """insert into platform.community (slug, name, timezone)
         values ($1, $2, $3)
         on conflict (slug) do nothing
         returning id""",
      @[textParam(slug), textParam(name), textParam(timezone)])
    if row.isNone:
      taken = true
    else:
      communityId = row.get.getUuid("id")
      # The first-admin invitation is bound to the address, not to a bearer
      # token: the account becomes admin the first time that email logs in.
      #
      # `community.invite` carries the tenant policy and this transaction's
      # connection has no tenant yet: it was checked out before the community
      # existed. Inserting on the bare connection would fail its `with check`
      # with SQLSTATE 42501 and roll back the platform.community row with it,
      # so the headline feature could not create a community at all. Declaring
      # the new id on this same connection is the fix; a second connection or a
      # second transaction would commit the community without its admin.
      discard db.scoped(communityId).boundTo(conn).execUpdate(
        """insert into community.invite
             (community_id, token_hash, email_hash, role, created_by)
           values ($1::uuid, decode($2,'hex'), $3, 'admin', $4::uuid)""",
        @[
          textParam(communityId),
          textParam(sha256Hex(newOpaqueToken())),
          textParam(sha256Hex(adminEmail.strip().toLowerAscii())),
          textOrNull(actorId),
        ]))
  if taken:
    CreateResult(status: csSlugTaken)
  else:
    CreateResult(status: csOk, communityId: communityId)

const selectSettingsSql* = """select values::text as values from community.settings
       where community_id = $1::uuid"""

proc settingsFrom*(row: Option[Row]): JsonNode =
  ## One row per community, so an absent row is an empty override set rather
  ## than an error: the platform value is the default.
  if row.isNone:
    newJObject()
  else:
    parseJson(row.get.get("values"))

proc currentSettings*(db: Db, communityId: string): JsonNode =
  ## The community's overrides. A request reads them once (through
  ## `CommunityContext.settings`) so two helpers in one handler cannot disagree
  ## or cost two round trips.
  settingsFrom(db.queryOne(selectSettingsSql, @[textParam(communityId)]))

proc directory*(db: Db, userId: Option[string], platformDefault: bool,
                key: string): JsonNode =
  ## Lists the communities this caller may see: opted-in ones plus their own.
  ## Entries never carry counts, owners or settings (COM-08).
  ##
  ## This read spans every community by design, so it is the one public route
  ## that cannot scope to any of them. Under the policy set the left join into
  ## `community.settings` yields no row, `coalesce` falls to the platform
  ## default, and every community turns invisible with a 200 and no log line,
  ## which reads exactly like every community opting out. The fix is the shape
  ## the plan picked: the root table names the communities, the settings and
  ## membership of each are read on a facade that declares it.
  result = newJArray()
  for community in db.query(
      "select id, slug, name from platform.community order by slug"):
    let communityId = community.get("id")
    let scoped = db.scoped(communityId)
    let settings = scoped.queryOne(
      "select (values ->> $1)::boolean as enabled from community.settings" &
      " where community_id = $2::uuid",
      @[textParam(key), textParam(communityId)])
    let enabled =
      if settings.isSome and settings.get["enabled"].isSome:
        settings.get.getBool("enabled")
      else:
        platformDefault
    var member = false
    if userId.isSome:
      member = scoped.queryOne(
        """select 1 as ok from community.membership
           where community_id = $1::uuid and user_id = $2::uuid""",
        @[textParam(communityId), textParam(userId.get)]).isSome
    if directoryVisible(enabled, member):
      result.add(directoryEntry(community.get("slug"), community.get("name")))
